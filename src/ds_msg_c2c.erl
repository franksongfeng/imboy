-module(ds_msg_c2c).
%%%
% ds_msg_c2c 是 msg_c2c domain service 缩写
%%%
-export([write_msg/6]).
-export([revoke_offline_msg/4]).
-export([read_msg/3]).
-export([delete_msg/1]).

-include("chat.hrl").
-include("common.hrl").


-spec write_msg(integer(),
                binary(),
                binary(),
                integer(),
                integer(),
                integer()) -> any().
%% 存储消息
write_msg(CreatedAt, Id, Payload, FromId, ToId, ServerTS) ->
    % 检查消息存储数量，如果数量大于limit 删除旧数据、插入新数据
    case repo_msg_c2c:count_by_to_id(ToId) of
        {ok, _, [[Count]]} when Count >= ?SAVE_MSG_LIMIT ->
            Limit = Count - ?SAVE_MSG_LIMIT + 1,
            repo_msg_c2c:delete_overflow_msg(ToId, Limit);
        _ ->
            ok
    end,
    repo_msg_c2c:write_msg(CreatedAt,
                           Id,
                           Payload,
                           FromId,
                           ToId,
                           ServerTS).


%% 读取消息
read_msg(ToUid, Limit, undefined) ->
    Column = <<"`id`, `payload`, `from_id`, `to_id`,
        `created_at`, `server_ts`, `msg_id`">>,
    Where = <<"WHERE `to_id` = ?">>,
    Vals = [ToUid],
    read_msg(Where, Vals, Column, Limit);
read_msg(ToUid, Limit, Ts) when is_binary(Ts) ->
    read_msg(ToUid, Limit, binary_to_integer(Ts));
read_msg(ToUid, Limit, Ts) ->
    Column = <<"`id`, `payload`, `from_id`, `to_id`,
        `created_at`, `server_ts`, `msg_id`">>,
    Where = <<"WHERE `to_id` = ? AND `created_at` > ?">>,
    Vals = [ToUid, Ts],
    read_msg(Where, Vals, Column, Limit).

delete_msg(Id) ->
    repo_msg_c2c:delete_msg(Id).


%% 撤销离线消息
-spec revoke_offline_msg(integer(), binary(), integer(), integer()) ->
          ok.
revoke_offline_msg(NowTs, Id, FromId, ToId) ->
    Payload = jsone:encode([{<<"msg_type">>, <<"custom">>},
                            {<<"custom_type">>, <<"revoked">>}]),
    % 存储消息
    ds_msg_c2c:write_msg(NowTs, Id, Payload, FromId, ToId, NowTs),
    Sql = <<"UPDATE `msg_c2c` SET `payload` = ? WHERE `msg_id` = ?">>,
    mysql_pool:query(Sql, [Payload, Id]),
    ok.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

read_msg(Where, Vals, Column, Limit) ->
    {ok, ColumnLi, Rows} = repo_msg_c2c:read_msg(
        Where,
        Vals,
        Column,
        Limit
    ),
    [lists:zipwith(fun(X, Y) -> {X, Y} end, ColumnLi, Row) || Row <- Rows].
