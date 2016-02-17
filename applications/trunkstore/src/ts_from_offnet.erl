%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz INC
%%% @doc
%%% Calls coming from offnet (in this case, likely stepswitch) potentially
%%% destined for a trunkstore client, or, if the account exists and
%%% failover is configured, to an external DID or SIP URI
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(ts_from_offnet).

-export([start_link/1, init/2]).

-include("ts.hrl").

-define(SERVER, ?MODULE).

-spec start_link(wh_json:object()) -> startlink_ret().
start_link(RouteReqJObj) ->
    proc_lib:start_link(?SERVER, 'init', [self(), RouteReqJObj]).

init(Parent, RouteReqJObj) ->
    proc_lib:init_ack(Parent, {'ok', self()}),
    start_amqp(ts_callflow:init(RouteReqJObj, ['undefined', <<"resource">>])).

-spec start_amqp(ts_callflow:state() |
                 {'error', 'not_ts_account'}
                ) -> 'ok'.
start_amqp({'error', 'not_ts_account'}) -> 'ok';
start_amqp(State) ->
    endpoint_data(ts_callflow:start_amqp(State)).

-spec endpoint_data(ts_callflow:state()) -> 'ok'.
endpoint_data(State) ->
    JObj = ts_callflow:get_request_data(State),
    try get_endpoint_data(JObj) of
        {'endpoint', Endpoint} ->
            proceed_with_endpoint(State, Endpoint, JObj)
    catch
        'throw':'no_did_found' ->
            lager:info("call was not for a trunkstore number");
        'throw':'unknown_account' -> 'ok';
        'throw':_E ->
            lager:info("thrown exception caught, not continuing: ~p", [_E])
    end.

-spec proceed_with_endpoint(ts_callflow:state(), wh_json:object(), wh_json:object()) -> 'ok'.
proceed_with_endpoint(State, Endpoint, JObj) ->
    CallID = ts_callflow:get_aleg_id(State),
    Q = ts_callflow:get_my_queue(State),
    'true' = wapi_dialplan:bridge_endpoint_v(Endpoint),

    MediaHandling = case wh_json:get_value([<<"Custom-Channel-Vars">>, <<"Offnet-Loopback-Number">>], JObj) of
                        'undefined' ->
                            case wh_util:is_false(wh_json:get_value(<<"Bypass-Media">>, Endpoint)) of
                                'true' -> <<"process">>; %% bypass media is false, process media
                                'false' -> <<"bypass">>
                            end;
                        _ -> <<"process">>
                    end,
    Command = [{<<"Application-Name">>, <<"bridge">>}
               ,{<<"Endpoints">>, [Endpoint]}
               ,{<<"Media">>, MediaHandling}
               ,{<<"Dial-Endpoint-Method">>, <<"single">>}
               ,{<<"Call-ID">>, CallID}
               | wh_api:default_headers(Q, <<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)
              ],
    State1 = ts_callflow:set_failover(State, wh_json:get_value(<<"Failover">>, Endpoint, wh_json:new())),
    State2 = ts_callflow:set_endpoint_data(State1, Endpoint),
    send_park(State2, Command).

send_park(State, Command) ->
    State1 = ts_callflow:send_park(State),
    wait_for_win(State1, Command).

wait_for_win(State, Command) ->
    case ts_callflow:wait_for_win(State) of
        {'lost', _} -> 'normal';
        {'won', State1} ->
            lager:info("route won, sending command"),
            send_onnet(State1, Command)
    end.

send_onnet(State, Command) ->
    lager:info("sending onnet command: ~p", [Command]),
    CtlQ = ts_callflow:get_control_queue(State),
    _ = wapi_dialplan:publish_command(CtlQ, Command),
    _ = wait_for_bridge(State),
    ts_callflow:send_hangup(State).

wait_for_bridge(State) ->
    case ts_callflow:wait_for_bridge(State) of
        {'hangup', _} -> 'ok';
        {'error', State1} ->
            lager:info("error waiting for bridge, try failover"),
            try_failover(State1)
    end.

try_failover(State) ->
    case {ts_callflow:get_control_queue(State)
          ,ts_callflow:get_failover(State)
         }
    of
        {<<>>, _} ->
            lager:info("no callctl for failover");
        {_, 'undefined'} ->
            lager:info("no failover defined");
        {_, Failover} ->
            case wh_json:is_empty(Failover) of
                'true' ->
                    lager:info("no failover configured");
                'false' ->
                    lager:info("trying failover"),
                    failover(State, Failover)
            end
    end.

failover(State, Failover) ->
    case wh_json:get_ne_value(<<"e164">>, Failover) of
        'undefined' ->
            try_failover_sip(State, wh_json:get_value(<<"sip">>, Failover));
        DID ->
            try_failover_e164(State, DID)
    end.

try_failover_sip(_, 'undefined') ->
    lager:info("SIP failover undefined");
try_failover_sip(State, SIPUri) ->
    CallID = ts_callflow:get_aleg_id(State),
    CtlQ = ts_callflow:get_control_queue(State),
    Q = ts_callflow:get_my_queue(State),
    lager:info("routing to failover sip uri: ~s", [SIPUri]),
    EndPoint = wh_json:from_list([{<<"Invite-Format">>, <<"route">>}
                                  ,{<<"Route">>, SIPUri}
                                 ]),
    %% since we only route to one endpoint, we specify most options on the endpoint's leg
    Command = [{<<"Call-ID">>, CallID}
               ,{<<"Application-Name">>, <<"bridge">>}
               ,{<<"Endpoints">>, [EndPoint]}
               | wh_api:default_headers(Q, <<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)
              ],
    wapi_dialplan:publish_command(CtlQ, Command),
    wait_for_bridge(ts_callflow:set_failover(State, wh_json:new())).

try_failover_e164(State, ToDID) ->
    RouteReq = ts_callflow:get_request_data(State),
    OriginalCIdNumber = wh_json:get_value(<<"Caller-ID-Number">>, RouteReq),
    OriginalCIdName = wh_json:get_value(<<"Caller-ID-Name">>, RouteReq),
    CallID = ts_callflow:get_aleg_id(State),
    AccountId = ts_callflow:get_account_id(State),

    Endpoint = ts_callflow:get_endpoint_data(State),

    CtlQ = ts_callflow:get_control_queue(State),
    Q = ts_callflow:get_my_queue(State),
    CCVs = ts_callflow:get_custom_channel_vars(State),

    Req = [{<<"Call-ID">>, CallID}
           ,{<<"Resource-Type">>, <<"audio">>}
           ,{<<"To-DID">>, ToDID}
           ,{<<"Account-ID">>, AccountId}
           ,{<<"Control-Queue">>, CtlQ}
           ,{<<"Application-Name">>, <<"bridge">>}
           ,{<<"Flags">>, wh_json:get_value(<<"flags">>, Endpoint)}
           ,{<<"Timeout">>, wh_json:get_value(<<"timeout">>, Endpoint)}
           ,{<<"Ignore-Early-Media">>, wh_json:get_value(<<"ignore_early_media">>, Endpoint)}
           ,{<<"Outbound-Caller-ID-Name">>, wh_json:get_value(<<"Outbound-Caller-ID-Name">>, Endpoint, OriginalCIdName)}
           ,{<<"Outbound-Caller-ID-Number">>, wh_json:get_value(<<"Outbound-Caller-ID-Number">>, Endpoint, OriginalCIdNumber)}
           ,{<<"Ringback">>, wh_json:get_value(<<"ringback">>, Endpoint)}
           ,{<<"Hunt-Account-ID">>, wh_json:get_value(<<"Hunt-Account-ID">>, Endpoint)}
           ,{<<"Custom-SIP-Headers">>, ts_callflow:get_custom_sip_headers(State)}
           ,{<<"Inception">>,  wh_json:get_value(<<"Inception">>, CCVs)}
           ,{<<"Custom-Channel-Vars">>, wh_json:from_list([{<<"Account-ID">>, AccountId}])}
           | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
          ],
    lager:info("sending offnet request for DID ~s", [ToDID]),
    wapi_offnet_resource:publish_req(props:filter_undefined(Req)),
    wait_for_bridge(ts_callflow:set_failover(State, wh_json:new())).

%%--------------------------------------------------------------------
%% Out-of-band functions
%%--------------------------------------------------------------------
-spec get_endpoint_data(wh_json:object()) -> {'endpoint', wh_json:object()}.
get_endpoint_data(JObj) ->
    {ToUser, _} = whapps_util:get_destination(JObj, ?APP_NAME, <<"inbound_user_field">>),
    ToDID = knm_converters:normalize(ToUser),
    case knm_number:lookup_account(ToDID) of
        {'ok', AccountId, NumberProps} ->
            get_endpoint_data(JObj, ToDID, AccountId, NumberProps);
        _Else ->
            lager:debug("unable to lookup account for number ~s: ~p", [ToDID, _Else]),
            throw('unknown_account')
    end.

-spec get_endpoint_data(wh_json:object(), ne_binary(), ne_binary(), wh_proplist()) -> {'endpoint', wh_json:object()}.
get_endpoint_data(JObj, ToDID, AccountId, NumberProps) ->
    ForceOut = wh_number_properties:should_force_outbound(NumberProps),
    lager:info("building endpoint for account id ~s with force out ~s", [AccountId, ForceOut]),
    RoutingData1 = routing_data(ToDID, AccountId),

    CidOptions  = proplists:get_value(<<"Caller-ID-Options">>, RoutingData1),
    CidFormat   = wh_json:get_ne_value(<<"format">>, CidOptions),
    OldCallerId = wh_json:get_value(<<"Caller-ID-Number">>, JObj),
    NewCallerId = whapps_call:maybe_format_caller_id_str(OldCallerId, CidFormat),
    RoutingData = RoutingData1 ++ [{<<"Outbound-Caller-ID-Number">>, NewCallerId}],

    AuthUser = props:get_value(<<"To-User">>, RoutingData),
    AuthRealm = props:get_value(<<"To-Realm">>, RoutingData),
    AuthzId = props:get_value(<<"Authorizing-ID">>, RoutingData),
    InFormat = props:get_value(<<"Invite-Format">>, RoutingData, <<"username">>),
    Invite = ts_util:invite_format(wh_util:to_lower_binary(InFormat), ToDID) ++ RoutingData,
    {'endpoint', wh_json:from_list(
                   [{<<"Custom-Channel-Vars">>, wh_json:from_list([{<<"Auth-User">>, AuthUser}
                                                                   ,{<<"Auth-Realm">>, AuthRealm}
                                                                   ,{<<"Direction">>, <<"inbound">>}
                                                                   ,{<<"Account-ID">>, AccountId}
                                                                   ,{<<"Authorizing-ID">>, AuthzId}
                                                                   ,{<<"Authorizing-Type">>, <<"sys_info">>}
                                                                  ])
                    }
                    | Invite
                   ])
    }.

-spec routing_data(ne_binary(), ne_binary()) -> [{<<_:48,_:_*8>>, any()}].
-spec routing_data(ne_binary(), ne_binary(), wh_json:object()) -> [{<<_:48,_:_*8>>, any()}].
routing_data(ToDID, AccountId) ->
    case ts_util:lookup_did(ToDID, AccountId) of
        {'ok', Settings} ->
            lager:info("got settings for DID ~s", [ToDID]),
            routing_data(ToDID, AccountId, Settings);
        {'error', 'no_did_found'} ->
            lager:info("DID ~s not found in ~s", [ToDID, AccountId]),
            throw('no_did_found')
    end.

routing_data(ToDID, AccountId, Settings) ->
    AuthOpts = wh_json:get_value(<<"auth">>, Settings, wh_json:new()),
    Acct = wh_json:get_value(<<"account">>, Settings, wh_json:new()),
    DIDOptions = wh_json:get_value(<<"DID_Opts">>, Settings, wh_json:new()),
    HuntAccountId = wh_json:get_value([<<"server">>, <<"hunt_account_id">>], Settings),
    RouteOpts = wh_json:get_value(<<"options">>, DIDOptions, []),
    NumConfig = case wh_number_manager:get_public_fields(ToDID, AccountId) of
                    {'ok', Fields} -> Fields;
                    {'error', _} -> wh_json:new()
                end,
    AuthU = wh_json:get_value(<<"auth_user">>, AuthOpts),
    AuthR = wh_json:find(<<"auth_realm">>, [AuthOpts, Acct]),

    {Srv, AcctStuff} =
        try ts_util:lookup_user_flags(AuthU, AuthR, AccountId, ToDID) of
            {'ok', AccountSettings} ->
                lager:info("got account settings"),
                {wh_json:get_value(<<"server">>, AccountSettings, wh_json:new())
                 ,wh_json:get_value(<<"account">>, AccountSettings, wh_json:new())
                }
        catch
            _E:_R ->
                lager:info("failed to get account settings: ~p: ~p", [_E, _R]),
                {wh_json:new(), wh_json:new()}
        end,

    SrvOptions = wh_json:get_value(<<"options">>, Srv, wh_json:new()),

    ToIP = wh_json:find(<<"ip">>, [AuthOpts, SrvOptions]),
    ToPort = wh_json:find(<<"port">>, [AuthOpts, SrvOptions]),

    case wh_json:is_true(<<"enabled">>, SrvOptions, 'true') of
        'false' -> throw({'server_disabled', wh_doc:id(Srv)});
        'true' -> 'ok'
    end,

    CidOptions = wh_json:get_ne_value(<<"caller_id_options">>, SrvOptions),

    InboundFormat = wh_json:get_value(<<"inbound_format">>, SrvOptions, <<"npan">>),
    {CalleeName, CalleeNumber} = callee_id([wh_json:get_value(<<"caller_id">>, DIDOptions)
                                            ,wh_json:get_value(<<"callerid_account">>, Settings)
                                            ,wh_json:get_value(<<"callerid_server">>, Settings)
                                           ]),
    ProgressTimeout = ts_util:progress_timeout([wh_json:get_value(<<"progress_timeout">>, DIDOptions)
                                                ,wh_json:get_value(<<"progress_timeout">>, SrvOptions)
                                                ,wh_json:get_value(<<"progress_timeout">>, AcctStuff)
                                               ]),
    BypassMedia = ts_util:bypass_media([wh_json:get_value(<<"media_handling">>, DIDOptions)
                                        ,wh_json:get_value(<<"media_handling">>, SrvOptions)
                                        ,wh_json:get_value(<<"media_handling">>, AcctStuff)
                                       ]),
    FailoverLocations = [wh_json:get_value(<<"failover">>, NumConfig)
                         ,wh_json:get_value(<<"failover">>, DIDOptions)
                         ,wh_json:get_value(<<"failover">>, SrvOptions)
                         ,wh_json:get_value(<<"failover">>, AcctStuff)
                        ],

    Failover = ts_util:failover(FailoverLocations),
    lager:info("failover found: ~p", [Failover]),

    Delay = ts_util:delay([wh_json:get_value(<<"delay">>, DIDOptions)
                           ,wh_json:get_value(<<"delay">>, SrvOptions)
                           ,wh_json:get_value(<<"delay">>, AcctStuff)
                          ]),
    SIPHeaders = ts_util:sip_headers([wh_json:get_value(<<"sip_headers">>, DIDOptions)
                                      ,wh_json:get_value(<<"sip_headers">>, SrvOptions)
                                      ,wh_json:get_value(<<"sip_headers">>, AcctStuff)
                                     ]),
    IgnoreEarlyMedia = ts_util:ignore_early_media([wh_json:get_value(<<"ignore_early_media">>, DIDOptions)
                                                   ,wh_json:get_value(<<"ignore_early_media">>, SrvOptions)
                                                   ,wh_json:get_value(<<"ignore_early_media">>, AcctStuff)
                                                  ]),
    Timeout = ts_util:ep_timeout([wh_json:get_value(<<"timeout">>, DIDOptions)
                                  ,wh_json:get_value(<<"timeout">>, SrvOptions)
                                  ,wh_json:get_value(<<"timeout">>, AcctStuff)
                                 ]),

    [KV || {_,V}=KV <- [ {<<"Invite-Format">>, InboundFormat}
                         ,{<<"Codecs">>, wh_json:find(<<"codecs">>, [SrvOptions, Srv])}
                         ,{<<"Bypass-Media">>, BypassMedia}
                         ,{<<"Endpoint-Progress-Timeout">>, ProgressTimeout}
                         ,{<<"Failover">>, Failover}
                         ,{<<"Endpoint-Delay">>, Delay}
                         ,{<<"Custom-SIP-Headers">>, SIPHeaders}
                         ,{<<"Ignore-Early-Media">>, IgnoreEarlyMedia}
                         ,{<<"Endpoint-Timeout">>, Timeout}
                         ,{<<"Callee-ID-Name">>, CalleeName}
                         ,{<<"Callee-ID-Number">>, CalleeNumber}
                         ,{<<"To-User">>, AuthU}
                         ,{<<"To-Realm">>, AuthR}
                         ,{<<"Caller-ID-Options">>, CidOptions}
                         ,{<<"To-DID">>, ToDID}
                         ,{<<"To-IP">>, build_ip(ToIP, ToPort)}
                         ,{<<"Route-Options">>, RouteOpts}
                         ,{<<"Hunt-Account-ID">>, HuntAccountId}
                         ,{<<"Authorizing-ID">>, wh_doc:id(Settings)} % connectivity doc id
                       ],
           V =/= 'undefined',
           V =/= <<>>
    ].

-spec build_ip(api_binary(), api_binary() | integer()) -> api_binary().
build_ip('undefined', _) -> 'undefined';
build_ip(IP, 'undefined') -> IP;
build_ip(IP, <<_/binary>> = PortBin) -> build_ip(IP, wh_util:to_integer(PortBin));
build_ip(IP, 5060) -> IP;
build_ip(IP, Port) -> list_to_binary([IP, ":", wh_util:to_binary(Port)]).

callee_id([]) -> {'undefined', 'undefined'};
callee_id(['undefined' | T]) -> callee_id(T);
callee_id([<<>> | T]) -> callee_id(T);
callee_id([JObj | T]) ->
    case wh_json:is_json_object(JObj) andalso (not wh_json:is_empty(JObj)) of
        'false' -> callee_id(T);
        'true' ->
            case {wh_json:get_value(<<"cid_name">>, JObj)
                  ,wh_json:get_value(<<"cid_number">>, JObj)}
            of
                {'undefined', 'undefined'} -> callee_id(T);
                CalleeID -> CalleeID
            end
    end.
