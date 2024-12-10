%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

%% @doc This module implelements the hook callback for multi-tenancy.
-module(emqx_mt_hookcb).

-export([
    register_hooks/0,
    on_session_created/2,
    on_authenticate/2
]).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").
-include_lib("emqx/include/logger.hrl").

-define(TRACE(MSG, META), ?TRACE("MULTI_TENANCY", MSG, META)).
register_hooks() ->
    Session = {?MODULE, on_session_created, []},
    ok = emqx_hooks:add('session.created', Session, ?HP_HIGHEST),
    Authn = {?MODULE, on_authenticate, []},
    ok = emqx_hooks:add('client.authenticate', Authn, ?HP_HIGHEST),
    ok.

on_session_created(
    #{
        clientid := ClientId,
        client_attrs := #{?CLIENT_ATTR_NAME_TNS := Tns}
    },
    _SessionInfo
) ->
    ?TRACE("session_registered_in_namespace", #{}),
    ok = emqx_mt_pool:add(Tns, ClientId, self());
on_session_created(_ClientInfo, _SessionInfo) ->
    %% not a multi-tenant client
    ok.

on_authenticate(
    #{clientid := ClientId, client_attrs := #{?CLIENT_ATTR_NAME_TNS := Tns}}, DefaultResult
) ->
    case emqx_mt_state:is_known_client(Tns, ClientId) of
        {true, Node} ->
            %% the client is re-connecting
            %% allow it to continue the authentication
            ?TRACE("existing_session_found", #{reside_in => Node}),
            DefaultResult;
        false ->
            case emqx_mt_state:count_clients(Tns) of
                {ok, Count} ->
                    Max = emqx_mt_config:get_max_sessions(Tns),
                    case Max =/= infinity andalso Count >= Max of
                        true ->
                            ?TRACE("session_count_quota_exceeded", #{}),
                            {stop, {error, quota_exceeded}};
                        false ->
                            ?TRACE("session_count_quota_available", #{}),
                            DefaultResult
                    end;
                {error, not_found} ->
                    %% TDOO: deny access when namespaces are managed by admin
                    %% so fart ns is created from client attributes
                    %% case emqx_mt_config:is_managed_ns() of
                    %%   true -> {stop, {error, not_auhorized}};
                    %%   false -> DefaultResult
                    %%  end
                    ?TRACE("first_clientid_in_namespace", #{}),
                    DefaultResult
            end
    end;
on_authenticate(_, DefaultResult) ->
    %% TDOO: deny access when namespaces is mandatory
    %% case emqx_mt_config:is_ns_mandatory() of
    %%   true -> {stop, {error, not_auhorized}};
    %%   false -> DefaultResult
    %% end
    ?TRACE("new_tenant_namespace", #{}),
    DefaultResult.
