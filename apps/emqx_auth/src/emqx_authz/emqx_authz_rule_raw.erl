%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc
%% This module converts authz rule fields obtained from
%% external sources like database or API to the format
%% accepted by emqx_authz_rule module.
%%--------------------------------------------------------------------

-module(emqx_authz_rule_raw).

-export([parse_rule/1, parse_and_compile_rules/1, format_rule/1]).

-include("emqx_authz.hrl").

%% Raw rules have the following format:
%%    [
%%        #{
%%            %% <<"allow">> | <"deny">>,
%%            <<"permission">> => <<"allow">>,
%%
%%            %% <<"pub">> | <<"sub">> | <<"all">>
%%            <<"action">> => <<"pub">>,
%%
%%            %% <<"a/$#">>, <<"eq a/b/+">>, ...
%%            <<"topic">> => TopicFilter,
%%
%%            %% when 'topic' is not provided
%%            <<"topics">> => [TopicFilter],
%%
%%            %%  0 | 1 | 2 | [0, 1, 2] | <<"0">> | <<"1">> | ...
%%            <<"qos">> => 0,
%%
%%            %% true | false | all | 0 | 1 | <<"true">> | ...
%%            %% only for pub action
%%            <<"retain">> => true,
%%
%%            %% Optional filters.
%%            %% Each filter should match for the rule to be appiled.
%%            <<"clientid_re">> => <<"^client-[0-9]+$">>,
%%            <<"username_re">> => <<"^user-[0-9]+$">>,
%%            <<"ipaddr">> => <<"192.168.5.0/24">>
%%        },
%%        ...
%%    ],
-type rule_raw() :: #{binary() => binary() | [binary()]}.
-type legacy_rule() :: {
    emqx_authz_rule:permission_resolution_precompile(),
    emqx_authz_rule:action_precompile(),
    emqx_authz_rule:topic_precompile()
}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Parse and compile raw ACL rules.
%% If any bad rule is found, `{bad_acl_rule, ..}' is thrown.
-spec parse_and_compile_rules([rule_raw()]) -> [emqx_authz_rule:rule()].
parse_and_compile_rules(Rules) ->
    lists:map(
        fun(Rule) ->
            case parse_rule(Rule) of
                {ok, {Permission, Who, Action, Topics}} ->
                    try
                        emqx_authz_rule:compile({Permission, Who, Action, Topics})
                    catch
                        throw:Reason ->
                            throw({bad_acl_rule, Reason})
                    end;
                {error, Reason} ->
                    throw({bad_acl_rule, Reason})
            end
        end,
        Rules
    ).

-spec parse_rule(rule_raw()) ->
    {ok, {
        emqx_authz_rule:permission_resolution_precompile(),
        emqx_authz_rule:who_precompile(),
        emqx_authz_rule:action_precompile(),
        emqx_authz_rule:topic_precompile()
    }}
    | {error, map()}.
parse_rule(
    #{
        <<"permission">> := PermissionRaw,
        <<"action">> := ActionTypeRaw
    } = RuleRaw
) ->
    try
        Topics = validate_rule_topics(RuleRaw),
        Permission = validate_rule_permission(PermissionRaw),
        Who = validate_rule_who(RuleRaw),
        ActionType = validate_rule_action_type(ActionTypeRaw),
        Action = validate_rule_action(ActionType, RuleRaw),
        {ok, {Permission, Who, Action, Topics}}
    catch
        throw:{Invalid, Which} ->
            {error, #{
                reason => Invalid,
                value => Which
            }}
    end;
parse_rule(RuleRaw) ->
    {error, #{
        reason => invalid_rule,
        value => RuleRaw,
        explain => "missing 'permission' or 'action' field"
    }}.

-spec format_rule(emqx_authz_rule:rule() | legacy_rule()) -> map().
format_rule({Permission, Action, Topics}) ->
    format_rule({Permission, all, Action, Topics});
format_rule({Permission, Who, Action, Topics}) when is_list(Topics) ->
    merge_maps(
        [
            #{
                topic => lists:map(fun format_topic/1, Topics),
                permission => Permission
            },
            format_action(Action),
            format_who(Who)
        ]
    );
format_rule({Permission, Who, Action, Topic}) ->
    merge_maps([
        #{
            topic => format_topic(Topic),
            permission => Permission
        },
        format_action(Action),
        format_who(Who)
    ]).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

validate_rule_topics(#{<<"topic">> := TopicRaw}) when is_binary(TopicRaw) ->
    [validate_rule_topic(TopicRaw)];
validate_rule_topics(#{<<"topics">> := TopicsRaw}) when is_list(TopicsRaw) ->
    lists:map(fun validate_rule_topic/1, TopicsRaw);
validate_rule_topics(RuleRaw) ->
    throw({missing_topic_or_topics, RuleRaw}).

validate_rule_topic(<<"eq ", TopicRaw/binary>>) ->
    {eq, TopicRaw};
validate_rule_topic(TopicRaw) when is_binary(TopicRaw) -> TopicRaw.

validate_rule_permission(<<"allow">>) -> allow;
validate_rule_permission(<<"deny">>) -> deny;
validate_rule_permission(PermissionRaw) -> throw({invalid_permission, PermissionRaw}).

validate_rule_action_type(P) when P =:= <<"pub">> orelse P =:= <<"publish">> -> publish;
validate_rule_action_type(S) when S =:= <<"sub">> orelse S =:= <<"subscribe">> -> subscribe;
validate_rule_action_type(<<"all">>) -> all;
validate_rule_action_type(ActionRaw) -> throw({invalid_action, ActionRaw}).

validate_rule_action(ActionType, RuleRaw) ->
    validate_rule_action(emqx_authz:feature_available(rich_actions), ActionType, RuleRaw).

%% rich_actions disabled
validate_rule_action(false, ActionType, _RuleRaw) ->
    ActionType;
%% rich_actions enabled
validate_rule_action(true, publish, RuleRaw) ->
    Qos = validate_rule_qos(maps:get(<<"qos">>, RuleRaw, ?DEFAULT_RULE_QOS)),
    Retain = validate_rule_retain(maps:get(<<"retain">>, RuleRaw, <<"all">>)),
    {publish, [{qos, Qos}, {retain, Retain}]};
validate_rule_action(true, subscribe, RuleRaw) ->
    Qos = validate_rule_qos(maps:get(<<"qos">>, RuleRaw, ?DEFAULT_RULE_QOS)),
    {subscribe, [{qos, Qos}]};
validate_rule_action(true, all, RuleRaw) ->
    Qos = validate_rule_qos(maps:get(<<"qos">>, RuleRaw, ?DEFAULT_RULE_QOS)),
    Retain = validate_rule_retain(maps:get(<<"retain">>, RuleRaw, <<"all">>)),
    {all, [{qos, Qos}, {retain, Retain}]}.

validate_rule_qos(QosInt) when is_integer(QosInt) andalso QosInt >= 0 andalso QosInt =< 2 ->
    [QosInt];
validate_rule_qos(QosBin) when is_binary(QosBin) ->
    try
        QosRawList = binary:split(QosBin, <<",">>, [global]),
        lists:map(fun validate_rule_qos_atomic/1, QosRawList)
    catch
        _:_ ->
            throw({invalid_qos, QosBin})
    end;
validate_rule_qos(QosList) when is_list(QosList) ->
    try
        lists:map(fun validate_rule_qos_atomic/1, QosList)
    catch
        invalid_qos ->
            throw({invalid_qos, QosList})
    end;
validate_rule_qos(undefined) ->
    ?DEFAULT_RULE_QOS;
validate_rule_qos(null) ->
    ?DEFAULT_RULE_QOS;
validate_rule_qos(QosRaw) ->
    throw({invalid_qos, QosRaw}).

validate_rule_qos_atomic(<<"0">>) -> 0;
validate_rule_qos_atomic(<<"1">>) -> 1;
validate_rule_qos_atomic(<<"2">>) -> 2;
validate_rule_qos_atomic(0) -> 0;
validate_rule_qos_atomic(1) -> 1;
validate_rule_qos_atomic(2) -> 2;
validate_rule_qos_atomic(QoS) -> throw({invalid_qos, QoS}).

validate_rule_retain(<<"0">>) -> false;
validate_rule_retain(<<"1">>) -> true;
validate_rule_retain(0) -> false;
validate_rule_retain(1) -> true;
validate_rule_retain(<<"true">>) -> true;
validate_rule_retain(<<"false">>) -> false;
validate_rule_retain(true) -> true;
validate_rule_retain(false) -> false;
validate_rule_retain(undefined) -> ?DEFAULT_RULE_RETAIN;
validate_rule_retain(null) -> ?DEFAULT_RULE_RETAIN;
validate_rule_retain(<<"all">>) -> ?DEFAULT_RULE_RETAIN;
validate_rule_retain(Retain) -> throw({invalid_retain, Retain}).

validate_rule_who(RuleRaw) ->
    case validate_rule_who(maps:to_list(RuleRaw), []) of
        [] -> all;
        [Who] -> Who;
        WhoList -> {'and', WhoList}
    end.

validate_rule_who([], WhoList) ->
    WhoList;
validate_rule_who([{<<"username_re">>, UsernameReRaw} | Rest], WhoList) when
    is_binary(UsernameReRaw)
->
    validate_rule_who(Rest, [{username, {re, UsernameReRaw}} | WhoList]);
validate_rule_who([{<<"username_re">>, UsernameReRaw} | _Rest], _WhoList) ->
    throw({invalid_username_re, UsernameReRaw});
validate_rule_who([{<<"clientid_re">>, ClientIdReRaw} | Rest], WhoList) when
    is_binary(ClientIdReRaw)
->
    validate_rule_who(Rest, [{clientid, {re, ClientIdReRaw}} | WhoList]);
validate_rule_who([{<<"clientid_re">>, ClientIdReRaw} | _Rest], _WhoList) ->
    throw({invalid_clientid_re, ClientIdReRaw});
validate_rule_who([{<<"ipaddr">>, IpAddrRaw} | Rest], WhoList) when is_binary(IpAddrRaw) ->
    validate_rule_who(Rest, [{ipaddr, binary_to_list(IpAddrRaw)} | WhoList]);
validate_rule_who([{<<"ipaddr">>, IpAddrRaw} | _Rest], _WhoList) ->
    throw({invalid_ipaddr, IpAddrRaw});
validate_rule_who([_ | Rest], WhoList) ->
    validate_rule_who(Rest, WhoList).

format_action(Action) ->
    format_action(emqx_authz:feature_available(rich_actions), Action).

%% rich_actions disabled
format_action(false, Action) when is_atom(Action) ->
    #{
        action => Action
    };
format_action(false, {ActionType, _Opts}) ->
    #{
        action => ActionType
    };
%% rich_actions enabled
format_action(true, Action) when is_atom(Action) ->
    #{
        action => Action
    };
format_action(true, {ActionType, Opts}) ->
    #{
        action => ActionType,
        qos => proplists:get_value(qos, Opts, ?DEFAULT_RULE_QOS),
        retain => proplists:get_value(retain, Opts, ?DEFAULT_RULE_RETAIN)
    }.

format_topic({eq, Topic}) when is_binary(Topic) ->
    <<"eq ", Topic/binary>>;
format_topic(Topic) when is_binary(Topic) ->
    Topic.

format_who(all) -> #{};
format_who({username, {re, UsernameRe}}) -> #{username_re => UsernameRe};
format_who({clientid, {re, ClientIdRe}}) -> #{clientid_re => ClientIdRe};
format_who({ipaddr, IpAddr}) when is_list(IpAddr) -> #{ipaddr => list_to_binary(IpAddr)};
format_who({'and', WhoList}) -> merge_maps(lists:map(fun format_who/1, WhoList));
format_who(Who) -> throw({invalid_who, Who}).

merge_maps(Maps) ->
    lists:foldl(fun(Map, Acc) -> maps:merge(Acc, Map) end, #{}, Maps).
