-module(imboy_db).

-export([list/1, list/2]).
-export([pluck/2]).
-export([pluck/3]).
-export([pluck/4]).

-export([query/1]).
-export([query/2]).
-export([execute/2, execute/3]).
-export([insert_into/3, insert_into/4]).
-export([assemble_sql/4]).

-export([get_set/1]).
-export([update/3]).
-export([update/4]).
-export([public_tablename/1]).

-export([with_transaction/1]).
-export([with_transaction/2]).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.
-include_lib("kernel/include/logger.hrl").
-include_lib("imlib/include/log.hrl").

%% ===================================================================
%% API
%% ===================================================================

-spec with_transaction(fun((epgsql:connection()) -> Reply)) ->
                              Reply | {rollback, any()}
                                  when
      Reply :: any().
with_transaction(F) ->
    with_transaction(F, [{reraise, false}]).

-spec with_transaction(fun((epgsql:connection()) -> Reply), epgsql:transaction_opts()) -> Reply | {rollback, any()} | no_return() when
      Reply :: any().
with_transaction(F, Opts0) ->
    Driver = config_ds:env(sql_driver),
    case pooler:take_member(Driver) of
        error_no_members ->
            % 休眠 1秒
            timer:sleep(1),
            with_transaction(F, Opts0);
        Conn ->
            Res = epgsql:with_transaction(Conn, F, Opts0),
            pooler:return_member(Driver, Conn),
            Res
    end.

% imboy_db:pluck(<<"SELECT to_tsquery('jiebacfg', '软件中国')"/utf8>>, <<"">>).

% pluck(<<"public.", Table/binary>>, Field, Default) ->
%     pluck(Table, Field, Default);
pluck(Table, Field, Default) ->
    Table2 = public_tablename(Table),
    Sql = <<"SELECT ", Field/binary, " FROM ", Table2/binary>>,
    % ?LOG([pluck, Sql]),
    pluck(Sql, Default).

pluck(Table, Where, Field, Default) ->
    Table2 = public_tablename(Table),
    Sql = <<"SELECT ", Field/binary, " FROM ", Table2/binary, " WHERE ", Where/binary>>,
    % ?LOG([pluck, Sql]),
    pluck(Sql, Default).

pluck(<<"SELECT ", Field/binary>>, Default) ->
    pluck(Field, Default);
pluck(Field, Default) ->
    Res = imboy_db:query(<<"SELECT ", Field/binary>>),
    % lager:info(io_lib:format("imboy_db:pluck/2 Field:~p ~n", [Field])),
    % lager:info(io_lib:format("imboy_db:pluck/2 Res:~p ~n", [Res])),
    case Res of
        {ok, _,[{Val}]} ->
            % lager:info(io_lib:format("imboy_db:pluck/2 Val:~p ~n", [Val])),
            Val;
        {ok, _, [Val]} ->
            Val;
        _ ->
            Default
    end.

list(Sql) ->
    case imboy_db:query(Sql) of
        {ok, _, Val} ->
            Val;
        _ ->
            []
    end.

list(Conn, Sql) ->
    case epgsql:equery(Conn, Sql) of
        {ok, _, Val} ->
            Val;
        _ ->
            []
    end.

% imboy_db:query("select * from user where id = 2")
-spec query(binary() | list()) -> {ok, list(), list()} | {error, any()}.
query(Sql) ->
    Driver = config_ds:env(sql_driver),
    Conn = pooler:take_member(Driver),
    Res = case Driver of
        pgsql when is_pid(Conn) ->
            epgsql:equery(Conn, Sql);
        pgsql when Conn == error_no_members->
            % 休眠 1秒
            timer:sleep(1),
            query(Sql);
        _ ->
            {error, not_supported}
    end,
    pooler:return_member(Driver, Conn),
    query_resp(Res).

-spec query(binary() | list(), list()) -> {ok, list(), list()} | {error, any()}.
query(Sql, Params) ->
    Driver = config_ds:env(sql_driver),
    Conn = pooler:take_member(Driver),
    Res = case Driver of
        pgsql when is_pid(Conn) ->
            epgsql:equery(Conn, Sql, Params);
        pgsql when Conn == error_no_members->
            % 休眠 1秒
            timer:sleep(1),
            query(Sql, Params);
        _ ->
            {error, not_supported}
    end,
    pooler:return_member(Driver, Conn),
    query_resp(Res).

-spec execute(any(), list()) ->
          {ok, LastInsertId :: integer()} | {error, any()}.
execute(Sql, Params) ->
    % ?LOG(io:format("~s\n", [Sql])),
    Driver = config_ds:env(sql_driver),
    Conn = pooler:take_member(Driver),
    Res = case Driver of
        pgsql when is_pid(Conn) ->
            % {ok, 1} | {ok, 1, {ReturningField}}
            execute(Conn, Sql, Params);
        pgsql when Conn == error_no_members->
            % 休眠 1秒
            timer:sleep(1),
            execute(Sql, Params);
        _ ->
            {error, not_supported}
    end,
    pooler:return_member(Driver, Conn),
    Res.

execute(Conn, Sql, Params) ->
    {ok, Stmt} = epgsql:parse(Conn, Sql),
    [Res0] = epgsql:execute_batch(Conn, [{Stmt, Params}]),
    % {ok, 1} | {ok, 1, {ReturningField}}
    Res0.


insert_into(Table, Column, Value) ->
    insert_into(Table, Column, Value, <<"RETURNING id;">>).

insert_into(Table, Column, Value, Returning) ->
    % Sql like this "INSERT INTO foo (k,v) VALUES (1,0), (2,0)"
    % return {ok,1,[{10}]}
    Sql = assemble_sql(<<"INSERT INTO">>, Table, Column, Value),
    imboy_db:execute(<<Sql/binary, " ", Returning/binary>>, []).


% 组装 SQL 语句
assemble_sql(Prefix, Table, Column, Value) when is_list(Column) ->
    ColumnBin = imboy_func:implode(",", Column),
    assemble_sql(Prefix, Table, <<"(", ColumnBin/binary, ")">>, Value);
assemble_sql(Prefix, Table, Column, Value) when is_list(Value) ->
    ValueBin = imboy_func:implode(",", Value),
    assemble_sql(Prefix, Table, Column, <<"(", ValueBin/binary, ")">>);
assemble_sql(Prefix, Table, Column, Value) ->
    Table2 = public_tablename(Table),
    Sql = <<Prefix/binary, " ", Table2/binary, " ", Column/binary,
            " VALUES ", Value/binary>>,
    % ?LOG(io:format("~s\n", [Sql])),
    Sql.

% imboy_db:update(<<"user">>, 1, <<"sign">>, <<"中国你好！😆"/utf8>>).
-spec update(binary(), binary(), binary(), list() | binary()) ->
    ok | {error,  {integer(), binary(), Msg::binary()}}.
update(Table, ID, Field, Value) when is_list(Value) ->
    update(Table, ID, Field, unicode:characters_to_binary(Value));
update(Table, ID, Field, Value) ->
    Table2 = public_tablename(Table),
    Sql = <<"UPDATE ", Table2/binary," SET ",
        Field/binary, " = $1 WHERE id = $2">>,
        % Field/binary, " = $1 WHERE ", Where/binary>>,
    imboy_db:execute(Sql, [Value, ID]).

% imboy_db:update(<<"user">>, <<"id = 1">>, [{<<"gender">>, <<"1">>}, {<<"nickname">>, <<"中国你好！2😆"/utf8>>}]).
-spec update(binary(), binary(), [list() | binary()]) ->
    ok | {error,  {integer(), binary(), Msg::binary()}}.
update(Table, Where, KV) when is_list(KV) ->
    Set = get_set(KV),
    update(Table, Where, Set);
update(Table, Where, KV) ->
    Table2 = public_tablename(Table),
    Sql = <<"UPDATE ", Table2/binary," SET ", KV/binary," WHERE ", Where/binary>>,
    % ?LOG(io:format("~s\n", [Sql])),
    imboy_db:execute(Sql, []).

-spec get_set(list()) -> binary().
get_set(KV) ->
    KV2 = [{K, update_filter_value(V)} || {K, V} <- KV],
    Set1 = [<<K/binary, " = '", V/binary, "'">> || {K, V} <- KV2],
    Set2 = [binary_to_list(S) || S <- Set1],
    Set3 = lists:concat(lists:join(", ", Set2)),
    list_to_binary(Set3).

%% ===================================================================
%% Internal Function Definitions
%% ===================================================================


query_resp({error, Msg}) ->
    {error, Msg};
query_resp({ok, Num}) ->
    {ok, Num};
query_resp({ok,[K], Rows}) ->
    % {ok,[<<"count">>],[{1}]}
    {ok, [K], Rows};
query_resp({ok, ColumnList, Rows}) ->
    % {ok,[{column,<<"max">>,int4,23,4,-1,1,0,0}],[{551223}]}
    % {ok,
    %     [{column,<<"count">>,int8,20,8,-1,1,0,0}]
    %     , [1]
    % }
    % lager:info(io_lib:format("imboy_db/query_resp: ColumnList ~p, Rows ~p ~n", [ColumnList, Rows])),
    ColumnList2 = [element(2, C) || C <- ColumnList],
    {ok, ColumnList2, Rows}.

public_tablename(<<"public.", Table/binary>>) ->
    public_tablename(Table);
public_tablename(Table) ->
    case config_ds:env(sql_driver) of
        pgsql ->
            <<"public.", Table/binary>>;
        _ ->
            Table
    end.

update_filter_value(Val) when is_binary(Val) ->
    Val;
update_filter_value(Val) ->
    unicode:characters_to_binary(Val).

%% ===================================================================
%% EUnit tests.
%% ===================================================================

-ifdef(EUNIT).

updateuser_test_() ->
    KV1 = [{<<"gender">>, <<"1">>}, {<<"nickname">>, <<"中国你好！😆"/utf8>>}],
    KV2 = [{<<"gender">>, <<"1">>}, {<<"nickname">>, "中国你好！😆😆"}],

    [
        ?_assert(imboy_db:update(<<"user">>, id, 1, KV1)),
        ?_assert(imboy_db:update(<<"user">>, id, 2, KV2))
    ].

-endif.
