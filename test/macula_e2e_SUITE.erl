%%%-------------------------------------------------------------------
%%% @doc Common Test wrapper around `macula_e2e_probe'.
%%%
%%% Bootstrap URL is configurable via the `MACULA_E2E_BOOTSTRAP'
%%% env var (comma-separated). Defaults to
%%% `https://boot.macula.io:4433'.
%%%
%%% The suite skips cleanly when no bootstrap is reachable —
%%% offline runs do not fail the build.
%%%
%%%   rebar3 ct --suite test/macula_e2e_SUITE
%%%   ./scripts/run-once.sh
%%%   docker run --rm --network host \
%%%     -e MACULA_E2E_BOOTSTRAP=https://station-be-kortrijk.macula.io:4433 \
%%%     ghcr.io/macula-internal/macula-e2e:latest
%%% @end
%%%-------------------------------------------------------------------
-module(macula_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).

%% Test cases
-export([
    pool_connect/1,
    pubsub_roundtrip/1,
    realm_isolation/1,
    unary_rpc/1,
    streaming_rpc/1,
    dht_put_find/1,
    weather_subscribe/1,
    pool_close_cleanup/1,
    put_get_content/1,
    cross_station_pubsub/1,
    cross_station_unary_rpc/1,
    cross_station_dht_put_find/1,
    cross_station_put_content/1
]).

-define(DEFAULT_BOOTSTRAP, [<<"https://boot.macula.io:4433">>]).
-define(WAIT_HEALTHY_MS,   30_000).
-define(WEATHER_WAIT_MS,   75_000).

%%====================================================================
%% CT callbacks
%%====================================================================

suite() ->
    [{timetrap, {minutes, 3}}].

all() ->
    [pool_connect,
     pubsub_roundtrip,
     realm_isolation,
     unary_rpc,
     streaming_rpc,
     dht_put_find,
     weather_subscribe,
     put_get_content,
     pool_close_cleanup,
     %% Cross-station hop probes — only run when MACULA_E2E_BOOTSTRAP_OTHER
     %% is set. Each tc skips cleanly when the second pool isn't wired.
     cross_station_pubsub,
     cross_station_unary_rpc,
     cross_station_dht_put_find,
     cross_station_put_content].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(macula),
    Bootstrap = bootstrap_seeds(),
    BootstrapOther = bootstrap_seeds_other(),
    ct:pal("[e2e] bootstrap        = ~p", [Bootstrap]),
    ct:pal("[e2e] bootstrap_other  = ~p", [BootstrapOther]),
    {ok, Pool}  = macula:connect(Bootstrap, #{}),
    {ok, Other} = macula:connect(Bootstrap, #{}),
    {CrossOpt, CrossPools} =
        case BootstrapOther of
            undefined -> {undefined, []};
            _ ->
                {ok, X} = macula:connect(BootstrapOther, #{}),
                {X, [X]}
        end,
    %% macula:connect/2 spawns gen_servers linked to the caller. CT's
    %% init_per_suite controller exits with Config as its reason after
    %% returning, killing the linked pools before any test case runs.
    %% Detach so the pools survive into the test cases + end_per_suite.
    unlink(Pool),
    unlink(Other),
    [unlink(P) || P <- CrossPools],
    on_initial_health(wait_for_healthy([Pool, Other | CrossPools],
                                       ?WAIT_HEALTHY_MS),
                      Pool, Other, CrossOpt, Bootstrap, BootstrapOther,
                      Config).

on_initial_health(ok, Pool, Other, Cross, Bootstrap, BootstrapOther, Config) ->
    {ok, #{healthy_links := N}} = macula:status(Pool),
    ct:pal("[e2e] pools ready — ~p healthy link(s) on shared pool",
           [N]),
    [{pool, Pool},
     {other, Other},
     {cross, Cross},
     {bootstrap, Bootstrap},
     {bootstrap_other, BootstrapOther},
     {test_realm,    macula_realm:id(<<"_test">>)},
     {test_realm_a,  macula_realm:id(<<"_test_a">>)},
     {test_realm_b,  macula_realm:id(<<"_test_b">>)},
     {weather_realm, macula_realm:id(<<"io.macula">>)} | Config];
on_initial_health(timeout, Pool, Other, Cross, Bootstrap, _BootstrapOther,
                  _Config) ->
    macula:close(Pool),
    macula:close(Other),
    close_if_set(Cross),
    {skip, {fleet_not_reachable, Bootstrap}}.

end_per_suite(Config) ->
    close_if_set(?config(pool, Config)),
    close_if_set(?config(other, Config)),
    close_if_set(?config(cross, Config)),
    ok.

close_if_set(undefined) -> ok;
close_if_set(Pool)      -> catch macula:close(Pool), ok.

%%====================================================================
%% Test cases — thin wrappers over macula_e2e_probe
%%====================================================================

pool_connect(Config) ->
    Pool = ?config(pool, Config),
    expect_ok(macula_e2e_probe:pool_health(Pool)).

pubsub_roundtrip(Config) ->
    Pub = ?config(pool, Config),
    Sub = ?config(other, Config),
    Realm = ?config(test_realm, Config),
    Topic = unique_topic(<<"e2e.pubsub">>),
    expect_ok(macula_e2e_probe:pubsub_roundtrip(Pub, Sub, Realm, Topic)).

realm_isolation(Config) ->
    Pub = ?config(pool, Config),
    Sub = ?config(other, Config),
    RealmA = ?config(test_realm_a, Config),
    RealmB = ?config(test_realm_b, Config),
    Topic = unique_topic(<<"e2e.isolation">>),
    expect_ok(macula_e2e_probe:realm_isolation(Pub, Sub, RealmA, RealmB, Topic)).

unary_rpc(Config) ->
    Server = ?config(pool, Config),
    Caller = ?config(other, Config),
    Realm = ?config(test_realm, Config),
    Procedure = unique_topic(<<"e2e.echo">>),
    expect_ok(macula_e2e_probe:unary_rpc(Server, Caller, Realm, Procedure)).

streaming_rpc(Config) ->
    Server = ?config(pool, Config),
    Caller = ?config(other, Config),
    Realm = ?config(test_realm, Config),
    Procedure = unique_topic(<<"e2e.count">>),
    expect_ok(macula_e2e_probe:streaming_rpc(Server, Caller, Realm, Procedure)).

dht_put_find(Config) ->
    Pool = ?config(pool, Config),
    Realm = ?config(test_realm, Config),
    expect_ok(macula_e2e_probe:dht_put_find(Pool, Realm)).

weather_subscribe(Config) ->
    Pool = ?config(pool, Config),
    Realm = ?config(weather_realm, Config),
    expect_ok(macula_e2e_probe:weather_subscribe(Pool, Realm,
                                                  ?WEATHER_WAIT_MS)).

pool_close_cleanup(Config) ->
    Bootstrap = ?config(bootstrap, Config),
    expect_ok(macula_e2e_probe:pool_close_cleanup(Bootstrap)).

put_get_content(Config) ->
    Pool = ?config(pool, Config),
    expect_ok(macula_e2e_probe:put_get_content(Pool)).

%%--------------------------------------------------------------------
%% Cross-station hop probes — exercise daemon→station→station→daemon.
%% Skip cleanly when MACULA_E2E_BOOTSTRAP_OTHER isn't set.
%%--------------------------------------------------------------------

cross_station_pubsub(Config) ->
    cross_or_skip(Config, fun(Pub, Sub) ->
        Realm = ?config(test_realm, Config),
        Topic = unique_topic(<<"e2e.cross.pubsub">>),
        macula_e2e_probe:cross_station_pubsub(Pub, Sub, Realm, Topic)
    end).

cross_station_unary_rpc(Config) ->
    cross_or_skip(Config, fun(Server, Caller) ->
        Realm = ?config(test_realm, Config),
        Procedure = unique_topic(<<"e2e.cross.echo">>),
        macula_e2e_probe:cross_station_unary_rpc(Server, Caller,
                                                  Realm, Procedure)
    end).

cross_station_dht_put_find(Config) ->
    cross_or_skip(Config, fun(Writer, Reader) ->
        Realm = ?config(test_realm, Config),
        macula_e2e_probe:cross_station_dht_put_find(Writer, Reader, Realm)
    end).

cross_station_put_content(Config) ->
    cross_or_skip(Config, fun(Writer, Reader) ->
        macula_e2e_probe:cross_station_put_content(Writer, Reader)
    end).

cross_or_skip(Config, Fun) ->
    case ?config(cross, Config) of
        undefined ->
            {skip, "MACULA_E2E_BOOTSTRAP_OTHER not set — "
                   "cross-station probe inactive"};
        Cross ->
            Pool = ?config(pool, Config),
            expect_ok(Fun(Pool, Cross))
    end.

%%====================================================================
%% Helpers
%%====================================================================

bootstrap_seeds() ->
    parse_seeds(os:getenv("MACULA_E2E_BOOTSTRAP"), ?DEFAULT_BOOTSTRAP).

bootstrap_seeds_other() ->
    case parse_seeds(os:getenv("MACULA_E2E_BOOTSTRAP_OTHER"), undefined) of
        undefined -> undefined;
        []        -> undefined;
        Seeds     -> Seeds
    end.

parse_seeds(false, Default) -> Default;
parse_seeds(Env,   _Default) ->
    [list_to_binary(string:trim(U))
     || U <- string:split(Env, ",", all),
        string:trim(U) =/= ""].

wait_for_healthy([], _Remaining) ->
    ok;
wait_for_healthy([Pool | Rest], Remaining) when Remaining =< 0 ->
    case macula:status(Pool) of
        {ok, #{healthy_links := N}} when N > 0 ->
            wait_for_healthy(Rest, 0);
        _ ->
            timeout
    end;
wait_for_healthy([Pool | Rest] = All, Remaining) ->
    case macula:status(Pool) of
        {ok, #{healthy_links := N}} when N > 0 ->
            wait_for_healthy(Rest, Remaining);
        _ ->
            timer:sleep(500),
            wait_for_healthy(All, Remaining - 500)
    end.

unique_topic(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<Prefix/binary, ".", Suffix/binary>>.

expect_ok(ok) ->
    ok;
expect_ok({error, Reason}) ->
    ct:fail({probe_failed, Reason}).
