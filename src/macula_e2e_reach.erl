%%%-------------------------------------------------------------------
%%% @doc Fleet reachability probe — dial each station, report identity.
%%%
%%% Answers the question every other probe assumes: which stations can
%%% this vantage point actually reach over QUIC, and which node id does
%%% each one answer with.
%%%
%%% The node id matters as much as the reachability. Retired station
%%% DNS on this fleet was repointed at the surviving station on its box
%%% rather than deleted, so a stale name still resolves and still
%%% connects — and every per-station claim built on it is then
%%% fabricated. Two names that answer with the SAME node id are one
%%% station wearing two hats, which is the failure this probe exists to
%%% make visible.
%%%
%%% Run it through `scripts/fleet-reach.sh'.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_e2e_reach).

-export([main/0, probe_all/0, probe/1, seed_url/1]).

-define(DIAL_TIMEOUT_MS, 20_000).
-define(POLL_MS,            250).

-type reach() :: #{station        := string(),
                   seed           := binary(),
                   reachable      := boolean(),
                   healthy_links  := non_neg_integer(),
                   failed_links   := non_neg_integer(),
                   node_id        := binary() | undefined,
                   dial_ms        := non_neg_integer(),
                   error          => term()}.

-export_type([reach/0]).

%%====================================================================
%% Entry point
%%====================================================================

%% @doc Probe every station and print a table. Halts non-zero when any
%% station is unreachable, so a scheduled run fails loudly.
-spec main() -> no_return().
main() ->
    {ok, _} = application:ensure_all_started(macula),
    Results = probe_all(),
    print_table(Results),
    print_identity_collisions(Results),
    halt(exit_code(Results)).

%% @doc Probe every station named by `macula_e2e_fleet:names/0'.
-spec probe_all() -> [reach()].
probe_all() ->
    [probe(S) || S <- macula_e2e_fleet:names()].

%%====================================================================
%% Probe
%%====================================================================

%% @doc Dial one station, wait for a healthy link, read its node id.
-spec probe(string()) -> reach().
probe(Station) ->
    Seed  = seed_url(Station),
    Start = erlang:monotonic_time(millisecond),
    Base  = #{station => Station, seed => Seed},
    on_connect(macula:connect([Seed], #{}), Base, Start).

on_connect({error, Reason}, Base, Start) ->
    Base#{reachable => false, healthy_links => 0, failed_links => 0,
          node_id => undefined, dial_ms => elapsed(Start),
          error => Reason};
on_connect({ok, Pool}, Base, Start) ->
    unlink(Pool),
    Healthy = wait_healthy(Pool, ?DIAL_TIMEOUT_MS),
    Result  = snapshot(Pool, Base, Start, Healthy),
    catch macula:close(Pool),
    Result.

snapshot(Pool, Base, Start, Healthy) ->
    {ok, #{healthy_links := H, failed_links := F}} = macula:status(Pool),
    Base#{reachable     => Healthy =:= ok,
          healthy_links => H,
          failed_links  => F,
          node_id       => peer_node_id(Pool),
          dial_ms       => elapsed(Start)}.

%% Node id of the first connected link. `undefined' before CONNECT/HELLO
%% completes, which is exactly the state we want reported rather than
%% waited out.
peer_node_id(Pool) ->
    {ok, Links} = macula:links(Pool),
    Connected   = [maps:get(node_id, L)
                   || L <- Links, maps:get(connected, L) =:= true],
    first_or_undefined([N || N <- Connected, N =/= undefined]).

first_or_undefined([])      -> undefined;
first_or_undefined([N | _]) -> N.

wait_healthy(_Pool, Left) when Left =< 0 ->
    timeout;
wait_healthy(Pool, Left) ->
    {ok, #{healthy_links := H}} = macula:status(Pool),
    on_health(H, Pool, Left).

on_health(H, _Pool, _Left) when H > 0 -> ok;
on_health(_H, Pool, Left) ->
    timer:sleep(?POLL_MS),
    wait_healthy(Pool, Left - ?POLL_MS).

elapsed(Start) ->
    erlang:monotonic_time(millisecond) - Start.

%% @doc Seed URL for a station short name.
-spec seed_url(string()) -> binary().
seed_url(Station) ->
    iolist_to_binary([<<"https://">>, Station,
                      macula_e2e_fleet:domain(),
                      <<":">>,
                      integer_to_binary(macula_e2e_fleet:port())]).

%%====================================================================
%% Reporting
%%====================================================================

print_table(Results) ->
    io:format("~n~-26s ~-10s ~-8s ~-8s ~-18s~n",
              ["station", "reachable", "healthy", "dial_ms", "node_id"]),
    io:format("~s~n", [lists:duplicate(74, $-)]),
    [print_row(R) || R <- Results],
    io:format("~n").

print_row(#{station := S, reachable := Ok, healthy_links := H,
            dial_ms := Ms} = R) ->
    io:format("~-26s ~-10s ~-8b ~-8b ~-18s~s~n",
              [S, atom_to_list(Ok), H, Ms, short_id(maps:get(node_id, R)),
               error_suffix(R)]).

error_suffix(#{error := E}) -> io_lib:format("  error=~p", [E]);
error_suffix(_)             -> "".

short_id(undefined) -> "-";
short_id(Bin) ->
    binary_to_list(binary:part(binary:encode_hex(Bin, lowercase), 0, 16)).

%% Two station names answering with one node id means one of them is a
%% repointed retired name. Any per-station claim across that pair is a
%% single station measured twice.
print_identity_collisions(Results) ->
    Pairs = [{maps:get(node_id, R), maps:get(station, R)}
             || R <- Results, maps:get(node_id, R) =/= undefined],
    Grouped = lists:foldl(fun group_by_node_id/2, #{}, Pairs),
    Collisions = [{Id, Names} || {Id, Names} <- maps:to_list(Grouped),
                                 length(Names) > 1],
    report_collisions(Collisions).

group_by_node_id({Id, Station}, Acc) ->
    maps:update_with(Id, fun(Names) -> [Station | Names] end, [Station], Acc).

report_collisions([]) ->
    io:format("identity collisions: none~n");
report_collisions(Collisions) ->
    io:format("IDENTITY COLLISIONS — these names are ONE station:~n"),
    [io:format("  ~s  <- ~s~n", [short_id(Id), string:join(Names, ", ")])
     || {Id, Names} <- Collisions],
    io:format("~n").

exit_code(Results) ->
    Unreachable = [R || R <- Results, maps:get(reachable, R) =:= false],
    code_for(Unreachable).

code_for([]) -> 0;
code_for(_)  -> 1.
