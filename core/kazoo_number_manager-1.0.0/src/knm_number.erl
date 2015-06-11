%%%-------------------------------------------------------------------
%%% @copyright (C) 2015, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Peter Defebvre
%%%-------------------------------------------------------------------
-module(knm_number).

-export([
    get/1
    ,create/2
    ,move/2
    ,update/2
    ,delete/1
]).

-include("knm.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get(number()) -> number_return().
get(Num) ->
    case knm_converters:is_reconcilable(Num) of
        'false' -> {'error', 'not_reconcilable'};
        'true' -> knm_phone_number:fetch(Num)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec create(number(), wh_proplist()) -> number_return().
create(Num, Props) ->
    NormalizedNum = knm_converters:normalize(Num),
    NumberDb = knm_converters:to_db(NormalizedNum),
    Updates =
        props:filter_undefined([
            {fun knm_phone_number:set_number/2, NormalizedNum}
            ,{fun knm_phone_number:set_number_db/2, NumberDb}
            ,{fun knm_phone_number:set_state/2, props:get_value(<<"state">>, Props, ?NUMBER_STATE_DISCOVERY)}
            ,{fun knm_phone_number:set_ported_in/2, props:get_is_true(<<"ported_in">>, Props, 'false')}
            ,{fun knm_phone_number:set_assigned_to/2, props:get_value(<<"assigned_to">>, Props)}
        ]),
    Number = knm_phone_number:setters(knm_phone_number:new(), Updates),
    knm_phone_number:save(Number).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec move(ne_binary(), ne_binary()) -> number_return().
move(Num, MoveTo) ->
    lager:debug("trying to move ~s to ~s", [Num, MoveTo]),
    case ?MODULE:get(Num) of
        {'error', _R}=E -> E;
        {'ok', Number} ->
            AccountId = wh_util:format_account_id(MoveTo, 'raw'),
            AssignedTo = knm_phone_number:assigned_to(Number),
            Props = [
                {fun knm_phone_number:set_assigned_to/2, AccountId}
                ,{fun knm_phone_number:set_prev_assigned_to/2, AssignedTo}
            ],
            UpdatedNumber = knm_phone_number:setters(Number, Props),
            knm_phone_number:save(UpdatedNumber)
    end.


%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec update(ne_binary(), wh_proplist()) -> number_return().
update(Num, Props) ->
    case ?MODULE:get(Num) of
        {'error', _R}=E -> E;
        {'ok', Number} ->
            UpdatedNumber = knm_phone_number:setters(Number, Props),
            knm_phone_number:save(UpdatedNumber)
    end.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec delete(ne_binary()) -> number_return().
delete(Num) ->
    case ?MODULE:get(Num) of
        {'error', _R}=E -> E;
        {'ok', Number} ->
            knm_phone_number:delete(Number)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
