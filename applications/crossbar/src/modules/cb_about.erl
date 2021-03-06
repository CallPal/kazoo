%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz
%%% @doc
%%% Display various informations
%%%
%%% @end
%%% @contributors
%%%   Edouard Swiac
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_about).

-export([init/0
         ,allowed_methods/0
         ,resource_exists/0
         ,validate/1
        ]).

-include("crossbar.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init() ->
    _ = crossbar_bindings:bind(<<"*.allowed_methods.about">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.about">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.validate.about">>, ?MODULE, 'validate').

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
allowed_methods() -> [?HTTP_GET].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
resource_exists() -> 'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
validate(Context) ->
    display_version(Context).

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% Display the current version of whistle
%% @end
%%--------------------------------------------------------------------
-spec display_version(cb_context:context()) -> cb_context:context().
display_version(Context) ->
    crossbar_util:response(
      wh_json:from_list(
        [{<<"version">>, wh_util:whistle_version()}
         ,{<<"used_memory">>, erlang:memory('total')}
         ,{<<"processes">>, erlang:system_info('process_count')}
         ,{<<"ports">>, length(erlang:ports())}
         ,{<<"erlang_version">>, wh_util:to_binary(erlang:system_info('otp_release'))}
        ]
       )
      ,Context
     ).
