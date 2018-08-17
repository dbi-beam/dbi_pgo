-module(dbi_pgo).
-author('manuel@altenwald.com').

-behaviour(dbi).

-export([
    start_link/2,
    init/8,
    terminate/1,
    do_query/3,
    check_migration/1,
    transaction/3,
    get_migrations/1,
    add_migration/3,
    rem_migration/2
]).

-include_lib("dbi/include/dbi.hrl").

-define(DEFAULT_POOLSIZE, 10).
-define(DEFAULT_PORT, 5432).

-spec start_link(atom(), map()) -> {ok, pid()}.

start_link(Name, DBConf) ->
    {ok, _} = pgo:start_pool(Name, DBConf).

-spec init(
    Host :: string(), Port :: integer(), User :: string(),
    Pass :: string(), Database :: string(), Poolname :: atom(),
    Poolsize :: integer(), Extra :: [term()]) -> ok.

init(Host, Port, User, Pass, Database, Poolname, Poolsize, _Extra) ->
    DataConn = [{host, dbi_config:to_charlist(Host)},
                {user, dbi_config:to_charlist(User)},
                {password, dbi_config:to_charlist(Pass)},
                {database, dbi_config:to_charlist(Database)},
                {port, dbi_query:default(Port, ?DEFAULT_PORT)},
                {size, dbi_query:default(Poolsize, ?DEFAULT_POOLSIZE)}],
    ChildSpec = dbi_app:child(?MODULE, [Poolname, DataConn]),
    supervisor:start_child(?DBI_SUP, ChildSpec),
    ok.

-spec terminate(Poolname :: atom()) -> ok.

terminate(_Poolname) ->
    ok.

-spec do_query(
    PoolDB :: atom(),
    SQL :: binary() | string(),
    [Params :: any()]) ->
    {ok, integer(), [term()]} | {error, any()}.

do_query(Poolname, SQL, Params) ->
    case pgo:query(Poolname, SQL, Params) of
        #{num_rows := NRows, rows := Rows} ->
            {ok, NRows, Rows};
        {pg_result, _Command, NRows, Rows} ->
            {ok, NRows, Rows};
        {error, {pgsql_error, #{code := Code, message := Message,
                                routine := Routine}}} ->
            {error, {Code, Routine, Message}};
        {error, Error} ->
            {error, Error}
    end.

-spec check_migration(PoolDB :: atom()) ->
      {ok, integer(), [binary()]}.

check_migration(PoolDB) ->
    Create = <<"CREATE TABLE IF NOT EXISTS schema_migrations("
               "id serial primary key not null, "
               "code text, "
               "filename text);">>,
    {ok, _, _} = do_query(PoolDB, Create, []),
    ok.

-spec transaction(PoolDB :: atom(), function(), Opts :: term()) ->
      {ok, integer(), [term()]} | {error, any()}.

transaction(PoolDB, Fun, _Opts) ->
    pgo:transaction(PoolDB, fun(Conn) ->
        Q = fun(Query, Args) ->
            do_query(Conn, Query, Args)
        end,
        Fun(Q)
    end).

-spec get_migrations(Poolname :: atom()) ->
      {ok, Count :: integer(), [{binary()}]}.

get_migrations(Poolname) ->
    SQL = <<"SELECT code, filename "
            "FROM schema_migrations "
            "ORDER BY id ASC">>,
    do_query(Poolname, SQL, []).

-spec add_migration(Poolname :: atom(), Code :: binary(), File :: binary()) ->
      ok | {error, Reason :: any()}.

add_migration(Poolname, Code, File) ->
    Insert = <<"INSERT INTO schema_migrations(code, filename) "
               "VALUES ($1, $2) RETURNING id">>,
    case do_query(Poolname, Insert, [Code, File]) of
        {ok, _, _} ->
            ok;
        Error ->
            Error
    end.

-spec rem_migration(Poolname :: atom(), Code :: binary()) ->
      ok | {error, Reason :: any()}.

rem_migration(Poolname, Code) ->
    Delete = <<"DELETE FROM schema_migrations "
               "WHERE code = $1">>,
    case do_query(Poolname, Delete, [Code]) of
        {ok, _, _} -> ok;
        Error -> Error
    end.
