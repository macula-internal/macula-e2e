%%%-------------------------------------------------------------------
%%% @doc The two-service torture — every application primitive macula
%%% offers, driven between two services on two DIFFERENT live stations.
%%%
%%% This exists so a service can be trusted on a live mesh: its far
%%% station restarts, its link drops, its peer refuses, and it keeps
%%% working without an operator.
%%%
%%% == Why two services and not two pools ==
%%%
%%% The existing probes open two pools against one bootstrap. That is
%%% the SDK talking to itself through one station, and it cannot see
%%% anything a relay does wrong. Here each service owns a pool pinned
%%% to a named station, and `distinct_stations/2' runs FIRST and hard
%%% fails if both pools answer with the same node id — which is exactly
%%% what happens on this fleet if a retired station name is used, since
%%% retired DNS was repointed rather than deleted.
%%%
%%% == What this covers that nothing else did ==
%%%
%%% Existing coverage is deep on wire-format correctness of the happy
%%% path and absent on LIFECYCLE. These rounds are the missing half:
%%%
%%% <ul>
%%%   <li>teardown — does `unsubscribe' stop delivery, does
%%%       `unadvertise' stop serving</li>
%%%   <li>refusal — does a handler's own reason survive a cross-station
%%%       hop (macula 8.0.0's headline contract), what does a caller see
%%%       when a handler crashes, when a procedure was never advertised,
%%%       when a handler outlives the deadline</li>
%%%   <li>survival — is the service still serving after its handler
%%%       crashed</li>
%%%   <li>ordering and duplication — asserted directly rather than
%%%       folded into a set, which is how the existing drains lose both</li>
%%%   <li>size — content across four orders of magnitude, not one
%%%       hardcoded 8 KiB</li>
%%% </ul>
%%%
%%% Every round returns `ok | {error, Reason}' and NOTHING is spawn
%%% linked into the caller, so a wedged pool is reported rather than
%%% killing the harness. That is deliberate: the existing concurrent
%%% probes `spawn_link' their workers and `exit(Pid, kill)' them at the
%%% end, so a slow sender — the exact symptom of the wedge they exist to
%%% detect — takes the probe down with no diagnostic.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_e2e_duel).

-export([main/0, main_fault/0, main_heal/0, main_puzzle/0,
         pair/0, run/2, run/3, rounds/0,
         fault_rounds/0, heal_rounds/0, puzzle_rounds/0,
         round_names/0, format/1]).

%% Individual rounds, exported so a CT suite can name one per test case.
-export([distinct_stations/2,
         pubsub_a_to_b/2, pubsub_b_to_a/2,
         pubsub_unsubscribe_stops_delivery/2,
         pubsub_ordering/2,
         pubsub_no_duplicates/2,
         rpc_echo_a_to_b/2, rpc_echo_b_to_a/2,
         rpc_refusal_reason_survives_hop/2,
         rpc_handler_crash_is_reported/2,
         rpc_service_survives_handler_crash/2,
         rpc_unknown_procedure_is_refused/2,
         rpc_unadvertise_stops_serving/2,
         rpc_readvertise_restores_serving/2,
         rpc_deadline_is_enforced/2,
         stream_order_and_eof/2,
         dht_put_find_cross/2,
         dht_find_records_by_type/2,
         dht_absent_key_is_not_found/2,
         content_put_get_cross/2,
         content_size_axis/2,
         torture_concurrent_calls/2,
         torture_sustained_pubsub/2,
         service_survives_station_pause/2,
         service_survives_station_restart/2,
         rpc_readvertise_heals/2,
         pubsub_wrapper_cross/2,
         rpc_wrapper_cross/2,
         streaming_wrapper_cross/2,
         content_wrapper_cross/2,
         quic_isolation_rpc_survives_large_content/2,
         dht_puzzle_accept/2,
         puzzle_reject_on_enforce/2]).

-define(SETTLE_MS,          3_000).
-define(EVENT_WAIT_MS,      8_000).
-define(SILENCE_WAIT_MS,    4_000).
-define(CALL_TIMEOUT_MS,   10_000).
-define(ORDERED_EVENTS,        25).
-define(CONCURRENT_CALLERS,    24).
-define(SUSTAINED_EVENTS,     120).
-define(SUSTAINED_GAP_MS,      25).
%% Walks the relay's 256 KiB chunk boundary from both sides, then past
%% it, so a failure lands on a size rather than on "big".
-define(CONTENT_SIZES, [1024, 65536, 262144, 262145, 1048576]).
-define(CONTENT_FETCH_ATTEMPTS, 4).
-define(CONTENT_RETRY_MS,   3_000).

%% Fault rounds. A stopped station's BEAM cold-boots (~20-30s measured on
%% milan) and the client pool then redials on its own backoff (up to
%% ?MAX_BACKOFF 60s), so recovery can take well over a minute. Poll,
%% don't sleep-once.
-define(FAULT_DWELL_MS,     12_000).
-define(FAULT_UP_WAIT_MS,  180_000).
-define(FAULT_POLL_MS,       2_000).
-define(FAULT_REPLAY_MS,    30_000).
%% Poll a re-advertised cross-hop call past the 30s reconcile period.
-define(HEAL_POLL_ATTEMPTS,   25).
-define(HEAL_POLL_MS,       2_000).
%% Bloom-exchange re-advertises a subscription to peers on ~30s cadence,
%% so the far station learning the replayed sub can take a minute-plus
%% after the link is back. Retry long enough to separate "slow to
%% reconverge" from "never replayed".
-define(FAULT_DELIVERY_RETRIES,   8).

%% Content over the 256 KiB chunk threshold, so a wrapper_cross feed
%% triggers a chunked put and therefore a content_announcement -- a
%% download_direct round with nothing under 256 KiB has no
%% announcement to resolve at all.
-define(WRAPPER_CONTENT_SIZE, 300_000).
%% A resolve can race DHT propagation (see CHANGELOG's
%% station_endpoint/content_announcement TTL-vs-replication-interval
%% notes) -- retry the whole feed+download attempt, not just the
%% resolve inside it, so "propagation was merely slow" and "never
%% arrives" are told apart the same way content_size_axis already
%% does for the plain path.
-define(WRAPPER_DIRECT_RETRIES,   3).
-define(WRAPPER_DIRECT_RETRY_MS, 5_000).
-define(WRAPPER_DIRECT_TIMEOUT_MS, 20_000).

%% QUIC isolation round: a feed past the chunk boundary, large enough
%% that transfer time dwarfs a unary call's own latency budget, so a
%% call stalled BEHIND it (no per-stream isolation) is unmistakable
%% from one merely queued behind normal jitter.
-define(ISOLATION_CONTENT_SIZE, 1_048_576).
-define(ISOLATION_RPC_CALLS,          5).
%% A call riding its own isolated stream should complete near
%% ?CALL_TIMEOUT_MS's own normal latency, not the seconds a 1 MiB
%% transfer over the same connection would take if genuinely stalled
%% behind it. Generous margin over ordinary RTT, tight against "stalled
%% behind the blob" (which would need most of the transfer's own
%% duration, several seconds).
-define(ISOLATION_RPC_BUDGET_MS, 3_000).

-type result()  :: ok | {error, term()}.
-type report()  :: [{atom(), result()}].

-export_type([result/0, report/0]).

%%====================================================================
%% Entry point
%%====================================================================

%% @doc Stand two services up on two stations, run every round, print
%% the report, exit non-zero on any failure.
-spec main() -> no_return().
main() ->
    {ok, _} = application:ensure_all_started(macula),
    {StationA, StationB} = pair(),
    RunId = run_id(),
    io:format("~n=== duel ~s ===~n  a: ~s~n  b: ~s~n~n",
              [RunId, StationA, StationB]),
    Report = with_services(StationA, StationB, RunId),
    io:format("~s", [format(Report)]),
    halt(exit_code(Report)).

%% @doc Stand two services up and run ONLY the fault rounds, which
%% deliberately restart a live station. Kept separate from `main/0'
%% because a routine duel must never disrupt the fleet, and because the
%% blast radius is a deliberate choice: this defaults service A onto a
%% degree-1 LEAF (stockholm), whose restart affects nothing that routes
%% through it, and pins B to that leaf's one upstream.
-spec main_fault() -> no_return().
main_fault() ->
    {ok, _} = application:ensure_all_started(macula),
    {StationA, StationB} = fault_pair(),
    RunId = run_id(),
    io:format("~n=== duel FAULT ~s ===~n  a (RESTARTED): ~s~n  b: ~s~n~n",
              [RunId, StationA, StationB]),
    Report = with_services_run(StationA, StationB, RunId, fault_rounds()),
    io:format("~s", [format(Report)]),
    halt(exit_code(Report)).

%% @doc Verify the advertise-reconcile fix on the two-hop pair: run the
%% re-advertise heal round, which polls PAST the ~30s reconcile period.
%% Before the fix a wedged re-advertise was permanent, so this round
%% timed out on ~half of runs; after it, a wedge heals within a reconcile
%% period and the round passes every time. Run it repeatedly (see
%% `scripts/duel-heal.sh') — the discriminator is zero permanent
%% failures across many runs, not any single run.
-spec main_heal() -> no_return().
main_heal() ->
    {ok, _} = application:ensure_all_started(macula),
    {StationA, StationB} = parse_pair_default(os:getenv("MACULA_E2E_DUEL_PAIR"),
                                              macula_e2e_fleet:two_hop_pair()),
    RunId = run_id(),
    io:format("~n=== duel HEAL ~s ===~n  a: ~s~n  b: ~s~n~n",
              [RunId, StationA, StationB]),
    Report = with_services_run(StationA, StationB, RunId, heal_rounds()),
    io:format("~s", [format(Report)]),
    halt(exit_code(Report)).

%% @doc Stand two services up and run ONLY the DHT-puzzle rounds. Kept
%% separate from `main/0' for the same reason as `main_fault/0': the
%% reject-path round temporarily flips a live station's puzzle
%% enforcement mode, so it must never run as a side effect of a
%% routine duel. Defaults to the same leaf-first pair as the fault
%% rounds -- stockholm (service A here, same as `fault_pair/0' puts it
%% for `main_fault/0') is a degree-1 leaf, so its config flip and the
%% brief connect-refusal it causes affect nothing that routes through it.
-spec main_puzzle() -> no_return().
main_puzzle() ->
    {ok, _} = application:ensure_all_started(macula),
    {StationA, StationB} = fault_pair(),
    RunId = run_id(),
    io:format("~n=== duel PUZZLE ~s ===~n  a (ENFORCEMENT FLIPPED): ~s~n  b: ~s~n~n",
              [RunId, StationA, StationB]),
    Report = with_services_run(StationA, StationB, RunId, puzzle_rounds()),
    io:format("~s", [format(Report)]),
    halt(exit_code(Report)).

%% Leaf first, so the station this run stops and starts is the one with
%% no inbound edges. Override with MACULA_E2E_DUEL_PAIR like the others.
fault_pair() ->
    parse_pair_default(os:getenv("MACULA_E2E_DUEL_PAIR"),
                       {"station-se-stockholm", "station-fi-helsinki"}).

parse_pair_default(false, Default) -> Default;
parse_pair_default("", Default)    -> Default;
parse_pair_default(Spec, _Default) -> two_of(string:tokens(Spec, ",")).

with_services(StationA, StationB, RunId) ->
    with_services_run(StationA, StationB, RunId, rounds()).

with_services_run(StationA, StationB, RunId, Rounds) ->
    on_service_a(macula_e2e_service:start(<<"a">>, StationA, RunId),
                 StationB, RunId, Rounds).

on_service_a({error, Reason}, _StationB, _RunId, _Rounds) ->
    [{service_a_start, {error, Reason}}];
on_service_a({ok, A}, StationB, RunId, Rounds) ->
    Report = on_service_b(macula_e2e_service:start(<<"b">>, StationB, RunId),
                          A, Rounds),
    macula_e2e_service:stop(A),
    Report.

on_service_b({error, Reason}, _A, _Rounds) ->
    [{service_b_start, {error, Reason}}];
on_service_b({ok, B}, A, Rounds) ->
    %% Advertises need to propagate to the far station before the first
    %% call crosses the hop, or the whole run measures propagation lag.
    timer:sleep(?SETTLE_MS),
    Report = run(A, B, Rounds),
    macula_e2e_service:stop(B),
    Report.

%% @doc The station pair to duel across.
%%
%% Defaults to `macula_e2e_fleet:two_hop_pair/0' — the one pair with no
%% direct edge in either direction, and therefore the fleet's only
%% genuine multi-hop path. Any other core pair is a single hop while
%% the data still reads as two. Override with
%% `MACULA_E2E_DUEL_PAIR=station-a,station-b'.
-spec pair() -> {string(), string()}.
pair() ->
    parse_pair(os:getenv("MACULA_E2E_DUEL_PAIR")).

parse_pair(false) -> macula_e2e_fleet:two_hop_pair();
parse_pair("")    -> macula_e2e_fleet:two_hop_pair();
parse_pair(Spec)  -> two_of(string:tokens(Spec, ",")).

two_of([A, B]) -> {string:trim(A), string:trim(B)};
two_of(Other)  -> error({bad_duel_pair, Other}).

%% Every name this run claims is namespaced by this, so a rerun never
%% lands on the previous run's station-side subscription and advertise
%% state.
run_id() ->
    integer_to_binary(erlang:system_time(second)).

exit_code(Report) ->
    code_for([R || {_N, R} <- Report, R =/= ok]).

code_for([]) -> 0;
code_for(_)  -> 1.

%%====================================================================
%% Runner
%%====================================================================

%% @doc Run every round once and return a report.
-spec run(macula_e2e_service:service(), macula_e2e_service:service()) ->
    report().
run(A, B) ->
    run(A, B, rounds()).

%% @doc Run a named subset. `distinct_stations' is always run first and
%% short-circuits the rest: if both services landed on one station,
%% every cross-station claim below it would be fabricated, and a
%% fabricated green is worse than a red.
-spec run(macula_e2e_service:service(), macula_e2e_service:service(),
          [atom()]) -> report().
run(A, B, Names) ->
    Gate = distinct_stations(A, B),
    on_gate(Gate, A, B, Names -- [distinct_stations]).

on_gate({error, _} = E, _A, _B, _Names) ->
    [{distinct_stations, E}];
on_gate(ok, A, B, Names) ->
    [{distinct_stations, ok}
     | [{N, run_one(N, A, B)} || N <- Names]].

%% A round that raises is a harness defect, not a mesh verdict, and the
%% two must never be confused in a report. Catching here is what keeps
%% one bad round from discarding the other twenty results.
run_one(Name, A, B) ->
    try ?MODULE:Name(A, B) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            {error, {round_raised, Name, Class, Reason, hd(Stack)}}
    end.

-spec rounds() -> [atom()].
rounds() ->
    [pubsub_a_to_b,
     pubsub_b_to_a,
     pubsub_unsubscribe_stops_delivery,
     pubsub_ordering,
     pubsub_no_duplicates,
     rpc_echo_a_to_b,
     rpc_echo_b_to_a,
     rpc_refusal_reason_survives_hop,
     rpc_handler_crash_is_reported,
     rpc_service_survives_handler_crash,
     rpc_unknown_procedure_is_refused,
     rpc_unadvertise_stops_serving,
     rpc_readvertise_restores_serving,
     rpc_deadline_is_enforced,
     stream_order_and_eof,
     dht_put_find_cross,
     dht_find_records_by_type,
     dht_absent_key_is_not_found,
     content_put_get_cross,
     content_size_axis,
     torture_concurrent_calls,
     torture_sustained_pubsub,
     pubsub_wrapper_cross,
     rpc_wrapper_cross,
     streaming_wrapper_cross,
     content_wrapper_cross,
     quic_isolation_rpc_survives_large_content,
     dht_puzzle_accept].

-spec round_names() -> [atom()].
round_names() -> [distinct_stations | rounds()].

%% @doc The fault rounds — deliberately absent from `rounds/0' because
%% each one disrupts a live station and must be run on purpose, never as
%% a side effect of a routine duel.
-spec fault_rounds() -> [atom()].
fault_rounds() ->
    [service_survives_station_pause,
     service_survives_station_restart].

%% @doc The advertise-reconcile verification round. Separate because it
%% polls for ~50s, far longer than the routine rounds.
-spec heal_rounds() -> [atom()].
heal_rounds() ->
    [rpc_readvertise_heals].

%% @doc The DHT-puzzle REJECT round — deliberately absent from
%% `rounds/0' because it flips a live station's puzzle enforcement
%% mode and must be run on purpose, never as a side effect of a
%% routine duel (same discipline as `fault_rounds/0'). The accept-path
%% round (`dht_puzzle_accept') is zero-risk -- no config touched -- and
%% already lives in `rounds/0' itself; it is not duplicated here.
-spec puzzle_rounds() -> [atom()].
puzzle_rounds() ->
    [puzzle_reject_on_enforce].

%% @doc Render a report as lines an operator can read at a glance.
-spec format(report()) -> iolist().
format(Report) ->
    Failed = [R || {_N, R} <- Report, R =/= ok],
    [[format_row(N, R), $\n] || {N, R} <- Report] ++
        [io_lib:format("~n~p/~p rounds passed~n",
                       [length(Report) - length(Failed), length(Report)])].

format_row(Name, ok) ->
    io_lib:format("  ok    ~s", [Name]);
format_row(Name, {error, Reason}) ->
    io_lib:format("  FAIL  ~s~n          ~p", [Name, Reason]).

%%====================================================================
%% Gate — are these really two stations
%%====================================================================

%% @doc Both services must be on distinct stations. Nothing else in
%% this module means anything otherwise.
-spec distinct_stations(macula_e2e_service:service(),
                        macula_e2e_service:service()) -> result().
distinct_stations(A, B) ->
    classify_identity(macula_e2e_service:node_id(A),
                      macula_e2e_service:node_id(B),
                      macula_e2e_service:station(A),
                      macula_e2e_service:station(B)).

classify_identity(undefined, _IdB, StA, _StB) ->
    {error, {no_node_id, StA}};
classify_identity(_IdA, undefined, _StA, StB) ->
    {error, {no_node_id, StB}};
classify_identity(Id, Id, StA, StB) ->
    {error, {same_station_behind_two_names, StA, StB, Id}};
classify_identity(_IdA, _IdB, _StA, _StB) ->
    ok.

%%====================================================================
%% Pub/sub
%%====================================================================

pubsub_a_to_b(A, B) -> pubsub_hop(A, B, <<"ab">>).
pubsub_b_to_a(A, B) -> pubsub_hop(B, A, <<"ba">>).

%% One publish, one subscriber, across the hop. Direction is a
%% parameter because the fleet's dial graph is DIRECTED and relay
%% routing tables are per-direction — every existing cross-station
%% probe only ever runs primary to cross.
pubsub_hop(From, To, Tag) ->
    Realm = macula_e2e_service:realm(From),
    Topic = macula_e2e_service:topic(From, <<"hop.", Tag/binary>>),
    {ok, Ref} = macula:subscribe(macula_e2e_service:pool(To), Realm, Topic,
                                 self()),
    timer:sleep(?SETTLE_MS),
    Payload = #{<<"tag">> => Tag, <<"n">> => 1},
    ok = macula:publish(macula_e2e_service:pool(From), Realm, Topic, Payload),
    Result = await_payload(Ref, Payload, ?EVENT_WAIT_MS),
    catch macula:unsubscribe(macula_e2e_service:pool(To), Ref),
    Result.

%% @doc After `unsubscribe/2', a publish must NOT be delivered.
%%
%% No probe in this repo has ever asserted this. Every one calls
%% `catch macula:unsubscribe(...)' as teardown and throws the result
%% away. It matters because a service that subscribes per session
%% accumulates state on the station for the pool's whole lifetime.
pubsub_unsubscribe_stops_delivery(A, B) ->
    Realm  = macula_e2e_service:realm(A),
    Topic  = macula_e2e_service:topic(A, <<"unsub">>),
    PoolA  = macula_e2e_service:pool(A),
    PoolB  = macula_e2e_service:pool(B),
    {ok, Ref} = macula:subscribe(PoolB, Realm, Topic, self()),
    timer:sleep(?SETTLE_MS),
    Live = confirm_live(PoolA, Realm, Topic, Ref),
    on_live_before_unsub(Live, PoolA, PoolB, Realm, Topic, Ref).

%% Proving delivery STOPS is worthless unless delivery was happening.
%% A subscription that never worked would otherwise pass this round.
confirm_live(PoolA, Realm, Topic, Ref) ->
    Probe = #{<<"phase">> => <<"before">>},
    ok = macula:publish(PoolA, Realm, Topic, Probe),
    await_payload(Ref, Probe, ?EVENT_WAIT_MS).

on_live_before_unsub({error, Reason}, _PoolA, _PoolB, _Realm, _Topic, _Ref) ->
    {error, {no_delivery_before_unsubscribe, Reason}};
on_live_before_unsub(ok, PoolA, PoolB, Realm, Topic, Ref) ->
    ok = macula:unsubscribe(PoolB, Ref),
    timer:sleep(?SETTLE_MS),
    ok = macula:publish(PoolA, Realm, Topic, #{<<"phase">> => <<"after">>}),
    expect_silence(Ref, ?SILENCE_WAIT_MS).

%% @doc Do events arrive in publish order?
%%
%% ⚠ macula specifies NOTHING about pubsub ordering — not that it holds,
%% not that it does not. Nothing in the SDK source, its guides, its
%% CHANGELOG or the station's routing code mentions per-topic order.
%% So this round is not asserting a broken promise; it is measuring an
%% unwritten one, because a consumer reading `publish' and `subscribe'
%% will assume order and any telemetry or game-state consumer breaks
%% quietly when it does not hold.
%%
%% Every existing drain folds payloads into a `sets:set', which
%% discards order by construction, so this is the first measurement of
%% it. The failure term carries an inversion count so the answer is
%% "how far out" rather than a boolean.
pubsub_ordering(A, B) ->
    Realm = macula_e2e_service:realm(A),
    Topic = macula_e2e_service:topic(A, <<"order">>),
    {ok, Ref} = macula:subscribe(macula_e2e_service:pool(B), Realm, Topic,
                                 self()),
    timer:sleep(?SETTLE_MS),
    Seq = lists:seq(1, ?ORDERED_EVENTS),
    [ok = macula:publish(macula_e2e_service:pool(A), Realm, Topic,
                         #{<<"i">> => I}) || I <- Seq],
    Got = collect_indices(Ref, length(Seq), ?EVENT_WAIT_MS, []),
    catch macula:unsubscribe(macula_e2e_service:pool(B), Ref),
    classify_order(Got, Seq).

classify_order(Seq, Seq)  -> ok;
classify_order(Got, Seq) ->
    classify_order_detail(lists:sort(Got) =:= Seq, Got, Seq).

classify_order_detail(true, Got, Seq) ->
    {error, {ordering_not_preserved, inversions, inversions(Got),
             of_pairs, length(Seq) * (length(Seq) - 1) div 2,
             arrival, Got}};
classify_order_detail(false, Got, Seq) ->
    {error, {missing_or_extra, got, Got, expected, Seq}}.

%% Pairs delivered in the wrong relative order. One inversion is a
%% single swap; a count near the pair total is delivery unrelated to
%% publish order. The distinction decides whether a consumer can
%% reorder with a small window or cannot reorder at all.
inversions(List) ->
    Indexed = lists:zip(lists:seq(1, length(List)), List),
    length([1 || {I, X} <- Indexed, {J, Y} <- Indexed, I < J, X > Y]).

%% @doc Exactly N publishes must yield exactly N deliveries.
%%
%% The existing multi-publisher probe claims to catch duplicates. It
%% cannot: it folds tokens into a set and simply does not decrement its
%% expected count when the set fails to grow, so a station delivering
%% every event twice passes it. Counting is the whole assertion here.
pubsub_no_duplicates(A, B) ->
    Realm = macula_e2e_service:realm(A),
    Topic = macula_e2e_service:topic(A, <<"dup">>),
    {ok, Ref} = macula:subscribe(macula_e2e_service:pool(B), Realm, Topic,
                                 self()),
    timer:sleep(?SETTLE_MS),
    Seq = lists:seq(1, ?ORDERED_EVENTS),
    [ok = macula:publish(macula_e2e_service:pool(A), Realm, Topic,
                         #{<<"i">> => I}) || I <- Seq],
    %% Drain PAST the expected count — a duplicate only shows up as an
    %% extra arrival after the last unique one.
    Got = drain_indices_until_quiet(Ref, ?EVENT_WAIT_MS, []),
    catch macula:unsubscribe(macula_e2e_service:pool(B), Ref),
    classify_duplicates(length(Got), lists:usort(Got), Seq).

classify_duplicates(N, Unique, Seq) when N =:= length(Seq),
                                         Unique =:= Seq ->
    ok;
classify_duplicates(N, Unique, Seq) when N > length(Seq) ->
    {error, {duplicate_delivery, received, N, unique, length(Unique),
             published, length(Seq)}};
classify_duplicates(N, Unique, Seq) ->
    {error, {lost_events, received, N, unique, length(Unique),
             published, length(Seq)}}.

%%====================================================================
%% Unary RPC
%%====================================================================

rpc_echo_a_to_b(A, B) -> rpc_echo(B, A).
rpc_echo_b_to_a(A, B) -> rpc_echo(A, B).

%% Server advertises, Caller calls, across the hop.
rpc_echo(Server, Caller) ->
    Args = #{<<"x">> => 42, <<"who">> => macula_e2e_service:name(Caller)},
    Reply = call(Caller, Server, <<"echo">>, Args, ?CALL_TIMEOUT_MS),
    classify_echo(Reply, Args).

classify_echo({ok, #{<<"got">> := Got}}, Args) -> match_args(Got, Args);
classify_echo({ok, #{got := Got}}, Args)       -> match_args(Got, Args);
classify_echo({ok, Other}, Args) -> {error, {unexpected_reply, Other,
                                             expected, Args}};
classify_echo({error, _} = E, _Args) -> E.

match_args(Got, Args) ->
    classify_match(normalise_keys(Got) =:= normalise_keys(Args), Got, Args).

classify_match(true, _Got, _Args) -> ok;
classify_match(false, Got, Args)  -> {error, {unexpected_reply, Got,
                                              expected, Args}}.

%% @doc A handler's own refusal reason must reach the caller.
%%
%% This is macula 8.0.0's headline contract. Before it, every refusal
%% in the world arrived as `{error, {call_error, 15, unknown_error}}'
%% and no service could tell a caller anything. The round exists to
%% prove the reason survives a RELAY, not just an in-process call —
%% the SDK's own tests cannot answer that.
rpc_refusal_reason_survives_hop(A, B) ->
    Reply = call(A, B, <<"refuse">>, #{}, ?CALL_TIMEOUT_MS),
    classify_refusal(Reply, macula_e2e_service:refusal_reason()).

classify_refusal({error, Reason}, Reason) ->
    ok;
%% A station-hosted handler's `{error, _}' comes back inside a RESULT
%% frame rather than an ERROR frame, so the caller sees `{ok, {error,
%% Reason}}'. Same handler source, different caller contract depending
%% on where it is hosted. Name it rather than passing it.
classify_refusal({ok, {error, Reason}}, Reason) ->
    {error, {refusal_arrived_as_success_frame, Reason}};
classify_refusal({error, {call_error, Code, Name}}, Expected) ->
    {error, {reason_lost_in_transit, got, {call_error, Code, Name},
             expected, Expected}};
classify_refusal(Other, Expected) ->
    {error, {unexpected_refusal_shape, Other, expected, Expected}}.

%% @doc A crashing handler must produce a failure at the caller, not a
%% hang and not a success.
rpc_handler_crash_is_reported(A, B) ->
    classify_crash(call(A, B, <<"crash">>, #{}, ?CALL_TIMEOUT_MS)).

classify_crash({error, _}) -> ok;
classify_crash({ok, Term}) -> {error, {crash_reported_as_success, Term}}.

%% @doc After a handler crashes, the service must still serve. A
%% supervisor that took the pool down with the handler would show up
%% here and nowhere else.
rpc_service_survives_handler_crash(A, B) ->
    _ = call(A, B, <<"crash">>, #{}, ?CALL_TIMEOUT_MS),
    timer:sleep(1_000),
    rpc_echo(B, A).

%% @doc Calling a procedure nobody advertised must fail.
rpc_unknown_procedure_is_refused(A, B) ->
    Realm = macula_e2e_service:realm(A),
    Proc  = macula_e2e_service:procedure(B, <<"never.advertised">>),
    Reply = macula:call(macula_e2e_service:pool(A), Realm, Proc, #{},
                        ?CALL_TIMEOUT_MS),
    classify_absent(Reply).

classify_absent({error, _}) -> ok;
classify_absent({ok, Term}) -> {error, {unknown_procedure_answered, Term}}.

%% @doc After `unadvertise/3', the procedure must stop serving.
%%
%% Never asserted anywhere. A service that re-advertises per session
%% leaks a routing entry per session, and a stale entry makes the relay
%% route a CALL to a handler that is gone.
%%
%% Deliberately leaves `echo' UNADVERTISED. Restoring it is the next
%% round's job, because whether it can be restored is itself a finding
%% and folding the two together hides it.
rpc_unadvertise_stops_serving(A, B) ->
    Live = rpc_echo(B, A),
    on_live_before_unadvertise(Live, A, B).

on_live_before_unadvertise({error, Reason}, _A, _B) ->
    {error, {no_service_before_unadvertise, Reason}};
on_live_before_unadvertise(ok, A, B) ->
    ok = macula_e2e_service:unadvertise(B, <<"echo">>),
    timer:sleep(?SETTLE_MS),
    Reply = call(A, B, <<"echo">>, #{<<"x">> => 1}, ?CALL_TIMEOUT_MS),
    classify_absent(Reply).

%% @doc Re-advertising must restore serving on the FAR station.
%%
%% Split out of the round above after a live run showed every
%% subsequent echo-using round failing with
%% `{call_error, 1, unknown_next_peer}' — the station had dropped its
%% route to the handler and did not take it back. This is the shape
%% every service hits on restart: a pool that re-advertises the same
%% procedure it advertised a moment ago must be servable again, or the
%% service is unreachable until something else evicts the stale route.
rpc_readvertise_restores_serving(A, B) ->
    macula_e2e_service:advertise_all(B),
    timer:sleep(?SETTLE_MS),
    classify_readvertise(rpc_echo(B, A), A, B).

classify_readvertise(ok, _A, _B) ->
    ok;
%% Give propagation a second, longer chance before calling it lost —
%% "slow to take the route back" and "never takes it back" are
%% different defects and the report must not merge them.
classify_readvertise({error, First}, A, B) ->
    timer:sleep(?SETTLE_MS * 3),
    classify_readvertise_retry(rpc_echo(B, A), First).

classify_readvertise_retry(ok, First) ->
    {error, {readvertise_took_over_12s, first_attempt, First}};
classify_readvertise_retry({error, Second}, First) ->
    {error, {readvertise_never_restored_route, first, First, retry, Second}}.

%% @doc Re-advertise must EVENTUALLY restore the route — within a reconcile
%% period, not never.
%%
%% This is the verification for the advertise-reconcile fix in
%% macula-station. The routine `rpc_readvertise_restores_serving' gives up
%% at ~12s, which is inside the 30s reconcile window, so it still shows the
%% wedge. This one unadvertises, re-advertises, and polls the cross-hop
%% call for ~50s. Before the fix a wedged re-advertise was PERMANENT, so
%% this timed out on the runs that wedged; after it, a wedge self-heals on
%% the next reconcile and this passes. The signal is zero failures across
%% many runs, since the immediate wedge rate is unchanged (~half) — only
%% whether it recovers.
rpc_readvertise_heals(A, B) ->
    Live = rpc_echo(B, A),
    on_heal_baseline(Live, A, B).

on_heal_baseline({error, Reason}, _A, _B) ->
    {error, {no_service_before_readvertise, Reason}};
on_heal_baseline(ok, A, B) ->
    ok = macula_e2e_service:unadvertise(B, <<"echo">>),
    timer:sleep(?SETTLE_MS),
    macula_e2e_service:advertise_all(B),
    poll_echo_heals(A, B, ?HEAL_POLL_ATTEMPTS).

poll_echo_heals(_A, _B, 0) ->
    {error, {readvertise_never_healed, waited_ms, ?HEAL_POLL_ATTEMPTS * ?HEAL_POLL_MS}};
poll_echo_heals(A, B, Left) ->
    on_heal_poll(rpc_echo(B, A), A, B, Left).

on_heal_poll(ok, _A, _B, Left) ->
    Waited = (?HEAL_POLL_ATTEMPTS - Left) * ?HEAL_POLL_MS,
    io:format("    healed after ~ps~n", [Waited div 1000]),
    ok;
on_heal_poll({error, _}, A, B, Left) ->
    timer:sleep(?HEAL_POLL_MS),
    poll_echo_heals(A, B, Left - 1).

%% @doc A handler slower than the deadline must time out at the caller,
%% and the caller must stay usable afterwards.
rpc_deadline_is_enforced(A, B) ->
    Deadline = macula_e2e_service:slow_delay_ms() div 3,
    Reply = call(A, B, <<"slow">>, #{}, Deadline),
    classify_deadline(Reply, A, B).

classify_deadline({ok, Term}, _A, _B) ->
    {error, {deadline_ignored, Term}};
classify_deadline({error, _}, A, B) ->
    %% The interesting half: the late reply must not corrupt the next
    %% call on the same pool.
    timer:sleep(macula_e2e_service:slow_delay_ms()),
    rpc_echo(B, A).

%%====================================================================
%% Streaming RPC
%%====================================================================

%% @doc A server_stream must deliver its chunks in order and then EOF.
stream_order_and_eof(A, B) ->
    Realm = macula_e2e_service:realm(A),
    Proc  = macula_e2e_service:procedure(B, <<"count">>),
    Opened = macula:call_stream(macula_e2e_service:pool(A), Realm, Proc,
                                #{<<"n">> => 8}, #{}),
    classify_stream_open(Opened).

classify_stream_open({error, _} = E) -> E;
classify_stream_open({ok, Stream}) ->
    classify_chunks(drain_stream(Stream, [])).

classify_chunks({ok, Chunks}) ->
    Expected = [integer_to_binary(I) || I <- lists:seq(1, 8)],
    classify_match(Chunks =:= Expected, Chunks, Expected);
classify_chunks({error, _} = E) -> E.

drain_stream(Stream, Acc) ->
    on_chunk(macula:recv(Stream, ?EVENT_WAIT_MS), Stream, Acc).

on_chunk({chunk, Bin}, Stream, Acc)     -> drain_stream(Stream, [Bin | Acc]);
on_chunk({data, Term}, Stream, Acc)     -> drain_stream(Stream, [Term | Acc]);
on_chunk(eof, _Stream, Acc)             -> {ok, lists:reverse(Acc)};
on_chunk({error, _} = E, _Stream, _Acc) -> E.

%%====================================================================
%% DHT records
%%====================================================================

%% @doc A record written through one station must be readable through
%% the other.
dht_put_find_cross(A, B) ->
    {Signed, Key} = fresh_record(macula_e2e_service:realm(A)),
    Put = macula:put_record(macula_e2e_service:pool(A), Signed),
    on_put(Put, B, Key).

on_put({error, _} = E, _B, _Key) -> E;
on_put(ok, B, Key) ->
    timer:sleep(?SETTLE_MS),
    classify_found(macula:find_record(macula_e2e_service:pool(B), Key), Key).

classify_found({ok, Record}, Key) ->
    classify_match(record_key(Record) =:= Key, record_key(Record), Key);
classify_found({error, _} = E, _Key) -> E.

record_key(#{key := K})      -> K;
record_key(#{<<"key">> := K}) -> K;
record_key(Other)             -> {no_key, Other}.

%% @doc The listing half of the DHT surface, never called anywhere.
%%
%% Asserted against the WRITER's station only. `find_records_by_type/2'
%% is documented as a per-station view — "each station sees its local
%% replicas plus whatever its peers have gossiped" — so a record absent
%% from the far station's listing is correct behaviour, not a defect.
%% Asserting a mesh-wide listing here would manufacture a red.
%%
%% The invariant that IS real: a station must list a record it just
%% accepted. The reader's view is collected alongside and reported as
%% information, because the gap between the two is the replication lag
%% and is worth seeing.
dht_find_records_by_type(A, B) ->
    {Signed, Key} = fresh_record(macula_e2e_service:realm(A)),
    Type = record_type(Signed),
    ok = macula:put_record(macula_e2e_service:pool(A), Signed),
    timer:sleep(?SETTLE_MS),
    Own = macula:find_records_by_type(macula_e2e_service:pool(A), Type),
    Far = macula:find_records_by_type(macula_e2e_service:pool(B), Type),
    classify_listed(Own, Key, Far).

classify_listed({ok, Records}, Key, Far) ->
    Keys = [record_key(R) || R <- Records],
    classify_membership(lists:member(Key, Keys), Key, length(Keys), Far);
classify_listed({error, _} = E, _Key, _Far) -> E.

classify_membership(true, _Key, _N, _Far) -> ok;
classify_membership(false, Key, N, Far) ->
    {error, {writer_station_does_not_list_own_record, Key,
             own_listing_size, N, far_listing, listing_size(Far)}}.

listing_size({ok, Records}) -> length(Records);
listing_size({error, R})    -> {error, R}.

record_type(#{type := T})       -> T;
record_type(#{<<"type">> := T}) -> T.

%% @doc A key nobody wrote must answer not-found, not success. A
%% station answering `not_found' for a record that exists is
%% indistinguishable from correct behaviour without this round.
dht_absent_key_is_not_found(A, _B) ->
    Key = crypto:strong_rand_bytes(32),
    classify_absent_record(macula:find_record(macula_e2e_service:pool(A),
                                              Key)).

classify_absent_record({error, _})  -> ok;
classify_absent_record({ok, Record}) ->
    {error, {absent_key_answered, record_key(Record)}}.

fresh_record(Realm) ->
    Identity = macula_identity:generate(),
    NodeId   = macula_identity:public(Identity),
    Record   = macula_record:node_record(NodeId, [Realm], 0,
                                         #{kind => <<"test_daemon">>}),
    Signed   = macula_record:sign(Record, Identity),
    {Signed, macula_record:storage_key(Signed)}.

%%====================================================================
%% Content addressing
%%====================================================================

%% @doc A blob written through one station must be readable through the
%% other, byte for byte.
content_put_get_cross(A, B) ->
    content_round_trip(A, B, 8192).

%% @doc Content across four orders of magnitude.
%%
%% Every content probe in this repo is hardcoded at 8192 bytes. The
%% real boundaries are the relay's 256 KiB chunk and the 16 MiB frame
%% cap, and `put_content/2' has no client-side chunking — its own doc
%% says an oversized blob surfaces as a CALL-deadline timeout rather
%% than a clean refusal. This walks up to them and reports the first
%% size that fails rather than stopping at the first success.
content_size_axis(A, B) ->
    Results = [{Size, content_round_trip(A, B, Size)}
               || Size <- ?CONTENT_SIZES],
    Failed = [{Size, R} || {Size, R} <- Results, R =/= ok],
    classify_sizes(Failed).

classify_sizes([])     -> ok;
classify_sizes(Failed) -> {error, {sizes_failed, Failed}}.

content_round_trip(A, B, Size) ->
    Bytes = crypto:strong_rand_bytes(Size),
    Put   = macula:put_content(macula_e2e_service:pool(A), Bytes),
    on_put_content(Put, B, Bytes).

on_put_content({error, Reason}, _B, Bytes) ->
    {error, {put_failed, byte_size(Bytes), Reason}};
on_put_content({ok, Mcid}, B, Bytes) ->
    fetch_with_retry(B, Mcid, Bytes, ?CONTENT_FETCH_ATTEMPTS, 0).

%% `put_content/2' answering ok means the WRITER's station stored the
%% blob, not that the reader's station can reach it. Retrying separates
%% the two failures that a single get cannot: a blob that is merely LATE
%% across the hop, and one that never arrives. Both are defects when put
%% has already answered ok, but they have different causes and a report
%% that merges them sends the reader to the wrong place.
fetch_with_retry(_B, _Mcid, Bytes, 0, Attempts) ->
    {error, {content_never_arrived, byte_size(Bytes), attempts, Attempts}};
fetch_with_retry(B, Mcid, Bytes, Left, Attempts) ->
    Got = macula:get_content(macula_e2e_service:pool(B), Mcid),
    classify_fetched(Got, Bytes, B, Mcid, Left, Attempts + 1).

classify_fetched({ok, Bytes}, Bytes, _B, _Mcid, _Left, 1) ->
    ok;
classify_fetched({ok, Bytes}, Bytes, _B, _Mcid, _Left, Attempts) ->
    {error, {content_arrived_late, byte_size(Bytes), attempts, Attempts}};
classify_fetched({ok, Other}, Bytes, _B, _Mcid, _Left, _Attempts) ->
    {error, {content_mismatch, got_bytes, byte_size(Other),
             expected_bytes, byte_size(Bytes)}};
classify_fetched({error, _Reason}, Bytes, B, Mcid, Left, Attempts) ->
    timer:sleep(?CONTENT_RETRY_MS),
    fetch_with_retry(B, Mcid, Bytes, Left - 1, Attempts).

%%====================================================================
%% Torture
%%====================================================================

%% @doc Many callers at once, across the hop.
%%
%% Workers are spawn_monitor'd, never spawn_link'd: a wedged pool must
%% be REPORTED, and linking makes the wedge kill the reporter.
torture_concurrent_calls(A, B) ->
    Self = self(),
    Tag  = make_ref(),
    Pids = [spawn_worker(Self, Tag, I, A, B)
            || I <- lists:seq(1, ?CONCURRENT_CALLERS)],
    Results = collect_workers(length(Pids), Tag, ?CALL_TIMEOUT_MS * 3, []),
    classify_concurrent(Results).

spawn_worker(Parent, Tag, I, A, B) ->
    {Pid, _Mon} = spawn_monitor(
        fun() ->
            Args  = #{<<"i">> => I},
            Reply = call(A, B, <<"echo">>, Args, ?CALL_TIMEOUT_MS),
            Parent ! {Tag, I, classify_echo(Reply, Args)}
        end),
    Pid.

collect_workers(0, _Tag, _Budget, Acc) ->
    Acc;
collect_workers(N, Tag, Budget, Acc) ->
    Started = erlang:monotonic_time(millisecond),
    receive
        {Tag, I, Result} ->
            collect_workers(N - 1, Tag, remaining(Budget, Started),
                            [{I, Result} | Acc]);
        {'DOWN', _Ref, process, _Pid, normal} ->
            collect_workers(N, Tag, remaining(Budget, Started), Acc);
        {'DOWN', _Ref, process, _Pid, Reason} ->
            collect_workers(N - 1, Tag, remaining(Budget, Started),
                            [{worker_died, {error, Reason}} | Acc])
    after Budget ->
        [{gave_up, {error, {workers_never_answered, N}}} | Acc]
    end.

remaining(Budget, Started) ->
    max(0, Budget - (erlang:monotonic_time(millisecond) - Started)).

classify_concurrent(Results) ->
    Failed = [R || {_I, R} <- Results, R =/= ok],
    classify_concurrent_detail(Failed, length(Results)).

classify_concurrent_detail([], N) when N =:= ?CONCURRENT_CALLERS -> ok;
classify_concurrent_detail([], N) ->
    {error, {answers_missing, got, N, expected, ?CONCURRENT_CALLERS}};
classify_concurrent_detail(Failed, _N) ->
    {error, {concurrent_calls_failed, length(Failed), hd(Failed)}}.

%% @doc Sustained publish at a fixed rate, counted exactly.
%%
%% Reports a delivery FRACTION rather than pass/fail on the first miss,
%% because "97% arrived" and "nothing arrived" are different defects
%% and a boolean cannot tell them apart.
torture_sustained_pubsub(A, B) ->
    Realm = macula_e2e_service:realm(A),
    Topic = macula_e2e_service:topic(A, <<"sustained">>),
    {ok, Ref} = macula:subscribe(macula_e2e_service:pool(B), Realm, Topic,
                                 self()),
    timer:sleep(?SETTLE_MS),
    Sender = spawn_sender(macula_e2e_service:pool(A), Realm, Topic),
    Got = drain_indices_until_quiet(Ref, ?EVENT_WAIT_MS, []),
    catch macula:unsubscribe(macula_e2e_service:pool(B), Ref),
    demonitor_sender(Sender),
    classify_sustained(lists:usort(Got)).

spawn_sender(Pool, Realm, Topic) ->
    spawn_monitor(
      fun() ->
          [begin
               macula:publish(Pool, Realm, Topic, #{<<"i">> => I}),
               timer:sleep(?SUSTAINED_GAP_MS)
           end || I <- lists:seq(1, ?SUSTAINED_EVENTS)],
          ok
      end).

%% The sender is monitored, not linked, and is never killed: a sender
%% still running is the symptom of the wedge being measured, and
%% killing it is how the existing probes destroy their own evidence.
demonitor_sender({Pid, Mon}) ->
    erlang:demonitor(Mon, [flush]),
    exit(Pid, shutdown),
    ok.

classify_sustained(Unique) when length(Unique) =:= ?SUSTAINED_EVENTS ->
    ok;
classify_sustained(Unique) ->
    {error, {sustained_delivery_incomplete, received, length(Unique),
             published, ?SUSTAINED_EVENTS,
             fraction, length(Unique) / ?SUSTAINED_EVENTS}}.

%%====================================================================
%% Cross-station supervised-primitive wrappers (macula 9.4.0-9.8.0)
%%
%% Same four wire operations as the routine rounds above, but driven
%% through the supervised OTP-behaviour wrappers, and -- for the three
%% pairs that have one -- via DIRECT-DIAL specifically: resolve the
%% far side from a signed DHT record and dial it in one hop, instead
%% of depending on advertise-gossip having propagated a route between
%% these two particular stations, which is exactly what a service
%% deployed to any two arbitrary stations cannot assume. Pubsub has no
%% direct-dial counterpart (Plumtree gossip, not a resolvable station
%% -- see `pubsub_two_stations.svg'), so its round stays on the
%% existing gossip-routed mechanism; it is still worth proving the
%% supervised wrapper pair itself survives a real cross-station hop.
%%====================================================================

%% @doc `macula_publisher' / `macula_subscriber', cross-station,
%% gossip-routed (pubsub's only mechanism).
pubsub_wrapper_cross(A, B) ->
    Realm = macula_e2e_service:realm(A),
    Topic = macula_e2e_service:topic(A, <<"wrapper_cross">>),
    {ok, SubPid} = macula_subscriber:start_link(
                     macula_e2e_wrapper_callback, macula_e2e_service:pool(B),
                     Realm, Topic, self()),
    timer:sleep(?SETTLE_MS),
    Token = crypto:strong_rand_bytes(16),
    Payload = #{<<"token">> => Token},
    {ok, PubPid} = macula_publisher:start_link(
                     macula_e2e_wrapper_callback, macula_e2e_service:pool(A),
                     Realm, Topic, Payload, self()),
    Result = await_wrapper_pub_sub(Topic, Payload, ?EVENT_WAIT_MS),
    catch gen_server:stop(SubPid),
    catch gen_server:stop(PubPid),
    Result.

%% Both the publisher's own outcome AND the subscriber's delivered
%% event must be observed -- a publisher reporting `ok' while nothing
%% arrives, or an arrival despite a reported publish failure, are both
%% real defects a single-sided check would miss.
await_wrapper_pub_sub(Topic, Payload, TimeoutMs) ->
    await_wrapper_pub_sub(Topic, Payload, TimeoutMs, undefined, undefined).

await_wrapper_pub_sub(_Topic, _Payload, _TimeoutMs, PubDone, SubDone)
        when PubDone =/= undefined, SubDone =/= undefined ->
    classify_pub_sub(PubDone, SubDone);
await_wrapper_pub_sub(Topic, Payload, TimeoutMs, PubDone, SubDone) ->
    receive
        {e2e_wrapper, published, Result} ->
            await_wrapper_pub_sub(Topic, Payload, TimeoutMs, Result, SubDone);
        {e2e_wrapper, sub_event, Topic, Got, _Meta} ->
            Match = normalise_keys(Got) =:= normalise_keys(Payload),
            await_wrapper_pub_sub(Topic, Payload, TimeoutMs, PubDone,
                                  {Match, Got})
    after TimeoutMs ->
        classify_pub_sub_timeout(PubDone, SubDone)
    end.

classify_pub_sub(ok, {true, _Got})  -> ok;
classify_pub_sub(ok, {false, Got})  -> {error, {payload_mismatch, Got}};
classify_pub_sub({error, _} = E, _) -> E.

classify_pub_sub_timeout(undefined, _) -> {error, publish_never_reported};
classify_pub_sub_timeout(_, undefined) -> {error, no_event};
classify_pub_sub_timeout(PubDone, SubDone) ->
    {error, {unexpected_state, PubDone, SubDone}}.

%% @doc `macula_response' / `macula_request', cross-station, via
%% DIRECT-DIAL: B publishes a discoverable `procedure_advertisement'
%% (`advertise_direct/6'), A resolves it and dials B in one hop
%% (`start_link_direct/7').
rpc_wrapper_cross(A, B) ->
    Realm     = macula_e2e_service:realm(A),
    Procedure = macula_e2e_service:procedure(B, <<"wrapper_cross">>),
    Identity  = macula_identity:generate(),
    {ok, Sup} = macula_response:advertise_direct(
                  macula_e2e_service:pool(B), Realm, Procedure,
                  macula_e2e_wrapper_callback, self(), Identity),
    timer:sleep(?SETTLE_MS),
    Args = #{<<"x">> => 42},
    {ok, ReqPid} = macula_request:start_link_direct(
                     macula_e2e_wrapper_callback, macula_e2e_service:pool(A),
                     Realm, Procedure, Args, ?WRAPPER_DIRECT_TIMEOUT_MS, self()),
    Result = await_wrapper_reply(Args, ?WRAPPER_DIRECT_TIMEOUT_MS),
    catch gen_server:stop(ReqPid),
    catch macula_response:unadvertise(macula_e2e_service:pool(B), Realm, Procedure),
    unlink(Sup),
    exit(Sup, shutdown),
    Result.

await_wrapper_reply(Args, TimeoutMs) ->
    receive
        {e2e_wrapper, req_reply, Reply} -> classify_wrapper_reply(Reply, Args)
    after TimeoutMs ->
        {error, {no_reply, expected, Args}}
    end.

classify_wrapper_reply({ok, #{echo := Got}}, Args) ->
    classify_match(normalise_keys(Got) =:= normalise_keys(Args), Got, Args);
classify_wrapper_reply({ok, #{<<"echo">> := Got}}, Args) ->
    classify_match(normalise_keys(Got) =:= normalise_keys(Args), Got, Args);
classify_wrapper_reply({ok, Other}, Args) ->
    {error, {unexpected_reply, Other, expected, Args}};
classify_wrapper_reply({error, _} = E, _) ->
    E.

%% @doc `macula_streamer' / `macula_stream_sink', cross-station, via
%% DIRECT-DIAL. Same shape as `rpc_wrapper_cross/2': one hop to B's own
%% resolved station, not dependent on a gossip-propagated route
%% existing between A and B.
streaming_wrapper_cross(A, B) ->
    Realm     = macula_e2e_service:realm(A),
    Procedure = macula_e2e_service:procedure(B, <<"wrapper_cross_stream">>),
    Identity  = macula_identity:generate(),
    {ok, StreamerSup} = macula_streamer:advertise_direct(
                           macula_e2e_service:pool(B), Realm, Procedure,
                           macula_e2e_wrapper_callback, self(), Identity),
    timer:sleep(?SETTLE_MS),
    {ok, SinkPid} = macula_stream_sink:start_link_direct(
                      macula_e2e_wrapper_callback, macula_e2e_service:pool(A),
                      Realm, Procedure, self()),
    Result = wrapper_stream_exchange(),
    catch gen_server:stop(SinkPid),
    catch macula_streamer:unadvertise(macula_e2e_service:pool(B), Realm, Procedure),
    unlink(StreamerSup),
    exit(StreamerSup, shutdown),
    Result.

wrapper_stream_exchange() ->
    receive
        {e2e_wrapper, stream_opened, _Args, StreamerPid} ->
            wrapper_stream_send(StreamerPid)
    after ?WRAPPER_DIRECT_TIMEOUT_MS ->
        {error, no_stream_opened}
    end.

wrapper_stream_send(StreamerPid) ->
    ok = macula_streamer:send(StreamerPid, <<"e2e-wrapper-cross-chunk">>),
    wrapper_stream_close(StreamerPid, wrapper_await_chunk()).

wrapper_await_chunk() ->
    receive
        {e2e_wrapper, sink_chunk, <<"e2e-wrapper-cross-chunk">>} -> ok;
        {e2e_wrapper, sink_chunk, Other} -> {error, {unexpected_chunk, Other}}
    after ?EVENT_WAIT_MS -> {error, chunk_timeout}
    end.

wrapper_stream_close(StreamerPid, ok) ->
    ok = macula_streamer:close(StreamerPid),
    receive
        {e2e_wrapper, sink_closed, _Reason} -> ok
    after ?EVENT_WAIT_MS -> {error, close_timeout}
    end;
wrapper_stream_close(_StreamerPid, Error) ->
    Error.

%% @doc `macula_feeder' / `macula_download', cross-station. A feeds via
%% the ordinary pooled `macula_feeder:start_link/5' -- content over the
%% 256 KiB chunk threshold, so the put triggers an automatic
%% `content_announcement', nothing to advertise explicitly. B downloads
%% via `macula_download:start_link_direct/4,5', DIRECT-DIALING A's
%% station to fetch it -- the harder, interesting direction, and the
%% one direct-dial download actually exists for. Retries the WHOLE
%% feed+download attempt, not just the resolve inside it, since a
%% resolve can race DHT propagation of the announcement (the exact
%% class of issue documented in CHANGELOG.md around
%% station_endpoint/content_announcement TTL vs. replication cadence).
content_wrapper_cross(A, B) ->
    content_wrapper_cross_attempt(A, B, ?WRAPPER_DIRECT_RETRIES).

content_wrapper_cross_attempt(_A, _B, 0) ->
    {error, content_direct_dial_never_resolved};
content_wrapper_cross_attempt(A, B, Left) ->
    Realm = macula_e2e_service:realm(A),
    Bytes = crypto:strong_rand_bytes(?WRAPPER_CONTENT_SIZE),
    {ok, FeederPid} = macula_feeder:start_link(
                        macula_e2e_wrapper_callback, macula_e2e_service:pool(A),
                        Realm, Bytes, self()),
    FedResult = receive
        {e2e_wrapper, fed, {ok, Mcid}} -> {ok, Mcid};
        {e2e_wrapper, fed, Other} -> {error, {feed_failed, Other}}
    after ?WRAPPER_DIRECT_TIMEOUT_MS -> {error, feed_timeout}
    end,
    catch gen_server:stop(FeederPid),
    on_wrapper_fed(FedResult, A, B, Realm, Bytes, Left).

on_wrapper_fed({error, _} = E, _A, _B, _Realm, _Bytes, _Left) ->
    E;
on_wrapper_fed({ok, Mcid}, A, B, Realm, Bytes, Left) ->
    {ok, DownloaderPid} = macula_download:start_link_direct(
                            macula_e2e_wrapper_callback, macula_e2e_service:pool(B),
                            Realm, Mcid, self()),
    Result = receive
        {e2e_wrapper, downloaded, {ok, Bytes}} -> ok;
        {e2e_wrapper, downloaded, {ok, Other}} ->
            {error, {content_mismatch, byte_size(Bytes), byte_size(Other)}};
        {e2e_wrapper, downloaded, Other} -> {error, {download_failed, Other}}
    after ?WRAPPER_DIRECT_TIMEOUT_MS -> {error, download_timeout}
    end,
    catch gen_server:stop(DownloaderPid),
    on_wrapper_download(Result, A, B, Left).

on_wrapper_download(ok, _A, _B, _Left) ->
    ok;
on_wrapper_download({error, _} = E, _A, _B, 1) ->
    E;
on_wrapper_download({error, _}, A, B, Left) ->
    timer:sleep(?WRAPPER_DIRECT_RETRY_MS),
    content_wrapper_cross_attempt(A, B, Left - 1).

%%====================================================================
%% QUIC per-stream isolation — the "sharper live head-of-line-blocking
%% demonstration" PLAN_PER_STREAM_QUIC_ISOLATION.md left as its one
%% open checklist item.
%%====================================================================

%% @doc B resolves A's content endpoint ONCE and reuses that exact URL
%% for both a large download and several concurrent unary RPC calls, so
%% both genuinely ride the SAME QUIC connection -- proving isolation
%% requires that, not just "separate stations". Asserts the RPC calls
%% complete within their normal latency budget while the download is in
%% flight, not stalled behind it.
quic_isolation_rpc_survives_large_content(A, B) ->
    Realm = macula_e2e_service:realm(A),
    Bytes = crypto:strong_rand_bytes(?ISOLATION_CONTENT_SIZE),
    Fed = isolation_feed_and_await(A, Realm, Bytes),
    on_isolation_fed(Fed, A, B, Realm, Bytes).

isolation_feed_and_await(A, Realm, Bytes) ->
    {ok, FeederPid} = macula_feeder:start_link(
                        macula_e2e_wrapper_callback, macula_e2e_service:pool(A),
                        Realm, Bytes, self()),
    Result = receive
        {e2e_wrapper, fed, {ok, Mcid}} -> {ok, Mcid};
        {e2e_wrapper, fed, Other} -> {error, {feed_failed, Other}}
    after ?WRAPPER_DIRECT_TIMEOUT_MS -> {error, feed_timeout}
    end,
    catch gen_server:stop(FeederPid),
    Result.

on_isolation_fed({error, _} = E, _A, _B, _Realm, _Bytes) -> E;
on_isolation_fed({ok, Mcid}, A, B, Realm, Bytes) ->
    on_isolation_resolved(
      macula_direct_dial:resolve_content_provider(macula_e2e_service:pool(B), Mcid),
      A, B, Realm, Mcid, Bytes).

on_isolation_resolved({error, Reason}, _A, _B, _Realm, _Mcid, _Bytes) ->
    {error, {content_not_resolved, Reason}};
on_isolation_resolved({ok, #{endpoint := Url, announcer_node := Node}},
                      A, B, Realm, Mcid, Bytes) ->
    Self = self(),
    TrustOpts = #{expected_node_id => Node, pin_tls_cert => false, verify => none},
    PoolB = macula_e2e_service:pool(B),
    {DlPid, DlMon} = spawn_monitor(fun() ->
        Result = macula:get_content_station(PoolB, Url, Mcid,
                                            ?WRAPPER_DIRECT_TIMEOUT_MS, TrustOpts),
        Self ! {isolation_download, Result}
    end),
    %% Let the download actually open its dedicated stream before the
    %% concurrent calls fire, so they land while the transfer is
    %% genuinely in flight rather than racing its own setup.
    timer:sleep(200),
    Procedure = macula_e2e_service:procedure(A, <<"echo">>),
    RpcResults = [timed_isolation_rpc(PoolB, Realm, Procedure, Url, TrustOpts, I)
                  || I <- lists:seq(1, ?ISOLATION_RPC_CALLS)],
    DownloadResult = await_isolation_download(DlPid, DlMon, Bytes),
    classify_isolation(RpcResults, DownloadResult).

timed_isolation_rpc(PoolB, Realm, Procedure, Url, TrustOpts, I) ->
    Started = erlang:monotonic_time(millisecond),
    %% macula:call_station/7's last arg is ONE opts map carrying both the
    %% UCAN token (under ucan_token, absent here) and the trust overrides
    %% -- there is no public /8 that takes them as separate positional
    %% args (that split happens internally, in macula_client). This call
    %% was never exercised until the DHT-walk fix made the resolve step
    %% upstream of it succeed for the first time, so the undef survived.
    Reply = macula:call_station(PoolB, Url, Realm, Procedure, #{<<"i">> => I},
                                ?CALL_TIMEOUT_MS, TrustOpts),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    {I, Elapsed, Reply}.

await_isolation_download(DlPid, DlMon, Bytes) ->
    receive
        {isolation_download, {ok, Bytes}} ->
            erlang:demonitor(DlMon, [flush]),
            ok;
        {isolation_download, {ok, Other}} ->
            erlang:demonitor(DlMon, [flush]),
            {error, {content_mismatch, byte_size(Bytes), byte_size(Other)}};
        {isolation_download, {error, _} = E} ->
            erlang:demonitor(DlMon, [flush]),
            E;
        {'DOWN', DlMon, process, DlPid, Reason} ->
            {error, {download_worker_died, Reason}}
    after ?WRAPPER_DIRECT_TIMEOUT_MS * 2 ->
        erlang:demonitor(DlMon, [flush]),
        exit(DlPid, kill),
        {error, download_timeout}
    end.

classify_isolation(RpcResults, {error, _} = DownloadError) ->
    {error, {download_failed, DownloadError, rpc_timings, RpcResults}};
classify_isolation(RpcResults, ok) ->
    Slow = [{I, Elapsed} || {I, Elapsed, _Reply} <- RpcResults,
                            Elapsed > ?ISOLATION_RPC_BUDGET_MS],
    Failed = [{I, Reply} || {I, _Elapsed, Reply} <- RpcResults,
                            not is_ok_reply(Reply)],
    classify_isolation_detail(Slow, Failed, RpcResults).

is_ok_reply({ok, _}) -> true;
is_ok_reply(_)        -> false.

classify_isolation_detail([], [], _RpcResults) -> ok;
classify_isolation_detail(Slow, [], RpcResults) ->
    {error, {rpc_stalled_behind_content, slow_calls, Slow, all_timings, RpcResults}};
classify_isolation_detail(_Slow, Failed, RpcResults) ->
    {error, {rpc_failed_during_content_transfer, Failed, all_timings, RpcResults}}.

%%====================================================================
%% DHT puzzle (S/Kademlia Sybil defense) — never exercised end-to-end
%% before this. `macula_station_listener:puzzle_decision/2': three
%% modes (`off'/`log_only'/`enforce'), default `off', read fresh per
%% handshake via `application:get_env(macula_station, puzzle_enforcement,
%% off)' -- no restart needed to flip. No deployed station sets this
%% today, so the whole fleet enforces nothing.
%%====================================================================

%% @doc Accept path: a puzzle-hardened identity connects to B's
%% station and can still make a plain call. Zero fleet risk -- no
%% config touched, exercises the existing default (`off', where every
%% identity is accepted regardless of puzzle validity) -- but proves a
%% VALID puzzle identity specifically is never rejected on principle.
dht_puzzle_accept(_A, B) ->
    Identity = macula_identity:generate(#{puzzle => true}),
    Seed = macula_e2e_fleet:seed_url(macula_e2e_service:station(B)),
    on_puzzle_connect(macula:connect([Seed], #{identity => Identity}), B).

on_puzzle_connect({error, _} = E, _B) -> E;
on_puzzle_connect({ok, Pool}, B) ->
    Result = on_puzzle_healthy(wait_puzzle_healthy(Pool, 15_000), Pool, B),
    catch macula:close(Pool),
    Result.

wait_puzzle_healthy(Pool, Left) when Left =< 0 ->
    {error, {timeout, macula:status(Pool)}};
wait_puzzle_healthy(Pool, Left) ->
    case macula:status(Pool) of
        {ok, #{healthy_links := N}} when N > 0 -> ok;
        _ -> timer:sleep(500), wait_puzzle_healthy(Pool, Left - 500)
    end.

on_puzzle_healthy({error, _} = E, _Pool, _B) -> E;
on_puzzle_healthy(ok, Pool, B) ->
    %% A trivial DHT round-trip proves the connection is genuinely
    %% usable, not merely "handshake completed".
    {Signed, Key} = fresh_record(macula_e2e_service:realm(B)),
    on_puzzle_put(macula:put_record(Pool, Signed), Pool, Key).

on_puzzle_put({error, _} = E, _Pool, _Key) -> E;
on_puzzle_put(ok, Pool, Key) ->
    timer:sleep(?SETTLE_MS),
    classify_found(macula:find_record(Pool, Key), Key).

%% @doc Reject path: with B's station flipped to `enforce', a connect
%% from a NON-puzzle-hardened identity must be refused. The actual
%% station-side behaviour is a silent `macula_peering:close/2' during
%% handshake (`macula_station_listener:reject_handshake/3'), not a
%% wire-level error frame, so the observable client-side shape is
%% "never becomes healthy", not a specific error code.
%%
%% Flips B back to `off' in an `after' clause no matter what happens,
%% mirroring `with_paused'/`with_stopped''s guaranteed-recovery
%% pattern, and does nothing else while `enforce' is live: this is NOT
%% risk-free the way the accept round is.
%% `macula_station_listener''s own moduledoc warns that `enforce'
%% rejects ANY identity that predates the puzzle check, which today is
%% the ENTIRE FLEET'S OWN inter-station identities -- flipping B can
%% disconnect it from its own upstream peer for the duration, not just
%% refuse this one test connection. Deliberately absent from
%% `rounds/0'; run only via `main_puzzle/0'.
puzzle_reject_on_enforce(_A, B) ->
    Station = macula_e2e_service:station(B),
    ok = macula_e2e_fault:set_puzzle_mode(Station, enforce),
    try
        attempt_non_puzzle_connect(Station)
    after
        catch macula_e2e_fault:set_puzzle_mode(Station, off)
    end.

%% `macula:status/1''s `healthy_links' is the WRONG signal here --
%% verified live 2026-08-21 against stockholm. It reflects the
%% CLIENT's own wire-level CONNECT/HELLO completion, which finishes
%% (and stays reported "healthy") entirely independent of the
%% server's puzzle decision, made one layer up in
%% `macula_station_listener:on_handshake_complete/3' AFTER the wire
%% handshake the client is measuring. A rejected identity never gets
%% promoted into that listener's `connected'/`peers' state (confirmed
%% live via `sys:get_state/1'), so its frames are never routed by
%% `peer_observer' -- but the client-side link worker has no way to
%% observe that and reports itself healthy regardless, including
%% through however many silent reject-reconnect cycles follow. A real
%% call is the only signal that actually distinguishes "accepted" from
%% "rejected": `find_record/2' against a system-served DHT procedure
%% every station answers natively returns `{error, not_found}' PROMPTLY
%% for an accepted peer (confirmed via every other round exercising it
%% all day) and times out for a peer whose frames are being silently
%% dropped (confirmed manually against stockholm under enforce: the
%% identical shape, a `{error, timeout}' where an accepted connection
%% gets a fast explicit answer).
attempt_non_puzzle_connect(Station) ->
    Seed = macula_e2e_fleet:seed_url(Station),
    Identity = macula_identity:generate(),  %% deliberately NOT puzzle-hardened
    {ok, Pool} = macula:connect([Seed], #{identity => Identity}),
    timer:sleep(?SETTLE_MS),
    Probe = macula:find_record(Pool, crypto:strong_rand_bytes(32)),
    Result = classify_reject(Probe),
    catch macula:close(Pool),
    Result.

classify_reject({error, timeout}) ->
    ok;
classify_reject({error, not_found}) ->
    {error, connection_not_refused_under_enforce};
classify_reject({ok, _} = Ok) ->
    {error, {connection_not_refused_under_enforce, Ok}};
classify_reject(Other) ->
    {error, {unexpected_reject_probe_result, Other}}.

%%====================================================================
%% Fault injection — a service must survive its far station failing
%%
%% This is the stated end goal of the whole harness: "its far station
%% restarts, its link drops, and it keeps working without an operator."
%% Nothing exercised it before; `macula_e2e_fault' existed with no
%% caller. These two rounds are the caller.
%%
%% Both restore the station in an `after' clause so a crashed assertion
%% cannot leave a production leaf down. The runner (`run_one/3') catches
%% exceptions rather than re-raising, so that `after' always runs before
%% the failure is recorded.
%%====================================================================

%% @doc A brief freeze must not break delivery. `docker pause' SIGSTOPs
%% the station's BEAM while its kernel sockets stay open, so the pool's
%% link is not severed — this tests riding through a transient stall,
%% the lighter failure, without a reconnect.
service_survives_station_pause(A, B) ->
    Station = macula_e2e_service:station(A),
    Realm   = macula_e2e_service:realm(A),
    Topic   = macula_e2e_service:topic(A, <<"pause">>),
    PoolA   = macula_e2e_service:pool(A),
    PoolB   = macula_e2e_service:pool(B),
    {ok, Ref} = macula:subscribe(PoolA, Realm, Topic, self()),
    timer:sleep(?SETTLE_MS),
    Baseline = confirm_delivery(PoolB, Realm, Topic, Ref, <<"before">>),
    on_baseline(Baseline,
                fun() -> after_pause(Station, PoolA, PoolB, Realm, Topic, Ref) end).

after_pause(Station, PoolA, PoolB, Realm, Topic, Ref) ->
    _ = macula_e2e_fault:with_paused(Station, fun pause_hold/0),
    timer:sleep(?SETTLE_MS),
    R = confirm_delivery(PoolB, Realm, Topic, Ref, <<"after">>),
    catch macula:unsubscribe(PoolA, Ref),
    R.

pause_hold() -> timer:sleep(?SETTLE_MS).

%% @doc THE round: a service survives its own station being stopped and
%% started, subscription intact.
%%
%% A subscribes (the wire subscription lands on A's station), B publishes
%% and A receives — baseline. Then A's station is STOPPED, so its BEAM
%% dies and the pool's link is genuinely severed. On start the station
%% cold-boots, the pool redials, re-handshakes, and REPLAYS the
%% subscription (`macula_client_replay:subs_to/2'). If replay works, B's
%% next publish reaches A. If it does not, A is silently deaf after every
%% station restart — which the fleet does daily on watchtower rolls.
service_survives_station_restart(A, B) ->
    Station = macula_e2e_service:station(A),
    Realm   = macula_e2e_service:realm(A),
    Topic   = macula_e2e_service:topic(A, <<"restart">>),
    PoolA   = macula_e2e_service:pool(A),
    PoolB   = macula_e2e_service:pool(B),
    {ok, Ref} = macula:subscribe(PoolA, Realm, Topic, self()),
    timer:sleep(?SETTLE_MS),
    Baseline = confirm_delivery(PoolB, Realm, Topic, Ref, <<"before">>),
    on_baseline(Baseline,
                fun() -> after_restart(Station, PoolA, PoolB, Realm,
                                       Topic, Ref) end).

after_restart(Station, PoolA, PoolB, Realm, Topic, Ref) ->
    ok = macula_e2e_fault:stop_station(Station),
    {Outage, LinkBack} = run_outage(Station, PoolA, PoolB, Realm, Topic, Ref),
    finish_restart(Outage, LinkBack, PoolA, PoolB, Realm, Topic, Ref).

%% Only proceed to the fault if delivery worked first — otherwise a
%% "survives" pass would be meaningless.
on_baseline({error, Reason}, _Continue) ->
    {error, {no_delivery_before_fault, Reason}};
on_baseline(ok, Continue) ->
    Continue().

%% Station is stopped on entry. Prove the outage is REAL by confirming
%% delivery has stopped (a publish from B, on a live station, must not
%% reach A whose station is down), then start it back and wait for A's
%% pool to reconnect.
%%
%% Confirming the outage from the client side, not from the down-edge of
%% a health counter, is deliberate: a passive subscriber's pool may not
%% notice a dead link for longer than any window worth waiting, and
%% "delivery actually stopped" is a stronger fact than "a counter
%% dipped" — it also cannot be fooled by a pool that reports a dead link
%% as healthy.
%%
%% The `after' guarantees the restart even if a step raises.
run_outage(Station, PoolA, PoolB, Realm, Topic, Ref) ->
    try
        timer:sleep(?FAULT_DWELL_MS),
        Outage = outage_silent(PoolB, Realm, Topic, Ref),
        ok = macula_e2e_fault:start_station(Station),
        {Outage, wait_link_up(PoolA, ?FAULT_UP_WAIT_MS)}
    after
        catch macula_e2e_fault:start_station(Station)
    end.

%% A publish from B while A's station is down must NOT reach A.
outage_silent(PoolB, Realm, Topic, Ref) ->
    _ = macula:publish(PoolB, Realm, Topic, #{<<"phase">> => <<"during">>}),
    expect_no_delivery(Ref, ?SILENCE_WAIT_MS).

finish_restart({error, delivered_during_outage}, _Up,
               _PoolA, _PoolB, _Realm, _Topic, _Ref) ->
    {error, {fault_did_not_take, delivery_continued_while_station_stopped}};
finish_restart(ok, timeout, _PoolA, _PoolB, _Realm, _Topic, _Ref) ->
    {error, {link_never_recovered, pool_did_not_redial_after_start}};
finish_restart(ok, up, PoolA, PoolB, Realm, Topic, Ref) ->
    %% Link is back; give the replay a moment to re-establish the wire
    %% subscription on the far station before testing delivery.
    timer:sleep(?FAULT_REPLAY_MS),
    R = confirm_delivery_retry(PoolB, Realm, Topic, Ref, <<"after">>,
                                          ?FAULT_DELIVERY_RETRIES),
    catch macula:unsubscribe(PoolA, Ref),
    classify_restart(R).

classify_restart(ok) ->
    ok;
classify_restart({error, Reason}) ->
    {error, {subscription_not_replayed_after_restart, Reason}}.

%% Poll the pool until it has a healthy link again, or time out.
wait_link_up(Pool, Budget) ->
    wait_link_up(Pool, Budget, erlang:monotonic_time(millisecond)).

wait_link_up(Pool, Budget, Start) ->
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    wait_link_step(healthy_links(Pool), Pool, Budget, Start, Elapsed).

wait_link_step(N, _Pool, _Budget, _Start, _Elapsed) when N > 0 ->
    up;
wait_link_step(_N, _Pool, Budget, _Start, Elapsed) when Elapsed >= Budget ->
    timeout;
wait_link_step(_N, Pool, Budget, Start, _Elapsed) ->
    timer:sleep(?FAULT_POLL_MS),
    wait_link_up(Pool, Budget, Start).

healthy_links(Pool) ->
    case macula:status(Pool) of
        {ok, #{healthy_links := N}} -> N;
        _                           -> 0
    end.

%% Returns ok if nothing arrives in the window (the outage is real), or
%% {error, delivered_during_outage} if a publish gets through anyway.
expect_no_delivery(Ref, TimeoutMs) ->
    receive
        {macula_event, Ref, _Topic, _Payload, _Meta} ->
            {error, delivered_during_outage}
    after TimeoutMs ->
        ok
    end.

%% One publish, one expected delivery, with a short wait.
confirm_delivery(PubPool, Realm, Topic, Ref, Tag) ->
    Payload = #{<<"phase">> => Tag},
    ok = macula:publish(PubPool, Realm, Topic, Payload),
    await_payload(Ref, Payload, ?EVENT_WAIT_MS).

%% Same, but retried: after a restart the far station's re-established
%% subscription and the routing between the two stations both need to
%% settle, and "arrived on the second try" is recovery, not failure.
confirm_delivery_retry(_PubPool, _Realm, _Topic, _Ref, _Tag, 0) ->
    {error, no_delivery_after_restart};
confirm_delivery_retry(PubPool, Realm, Topic, Ref, Tag, Left) ->
    Payload = #{<<"phase">> => Tag, <<"try">> => Left},
    ok = macula:publish(PubPool, Realm, Topic, Payload),
    on_retry(await_payload(Ref, Payload, ?EVENT_WAIT_MS),
             PubPool, Realm, Topic, Ref, Tag, Left).

on_retry(ok, _PubPool, _Realm, _Topic, _Ref, _Tag, _Left) ->
    ok;
on_retry({error, _}, PubPool, Realm, Topic, Ref, Tag, Left) ->
    confirm_delivery_retry(PubPool, Realm, Topic, Ref, Tag, Left - 1).

%%====================================================================
%% Shared helpers
%%====================================================================

call(Caller, Server, Suffix, Args, TimeoutMs) ->
    macula:call(macula_e2e_service:pool(Caller),
                macula_e2e_service:realm(Caller),
                macula_e2e_service:procedure(Server, Suffix),
                Args, TimeoutMs).

await_payload(Ref, Expected, TimeoutMs) ->
    Want = normalise_keys(Expected),
    receive
        {macula_event, Ref, _Topic, Got, _Meta} ->
            classify_match(normalise_keys(Got) =:= Want, Got, Expected)
    after TimeoutMs ->
        {error, {no_event, expected, Expected}}
    end.

expect_silence(Ref, TimeoutMs) ->
    receive
        {macula_event, Ref, _Topic, Got, _Meta} ->
            {error, {delivered_after_unsubscribe, Got}}
    after TimeoutMs ->
        ok
    end.

%% Collect exactly N indices, preserving arrival order.
collect_indices(_Ref, 0, _TimeoutMs, Acc) ->
    lists:reverse(Acc);
collect_indices(Ref, N, TimeoutMs, Acc) ->
    receive
        {macula_event, Ref, _Topic, Payload, _Meta} ->
            collect_indices(Ref, N - 1, TimeoutMs, [index_of(Payload) | Acc])
    after TimeoutMs ->
        lists:reverse(Acc)
    end.

%% Drain until the mesh goes quiet, so extras past the expected count
%% are observed instead of being left in the mailbox.
drain_indices_until_quiet(Ref, TimeoutMs, Acc) ->
    receive
        {macula_event, Ref, _Topic, Payload, _Meta} ->
            drain_indices_until_quiet(Ref, TimeoutMs,
                                      [index_of(Payload) | Acc])
    after TimeoutMs ->
        lists:reverse(Acc)
    end.

index_of(#{<<"i">> := I}) -> I;
index_of(#{i := I})       -> I;
index_of(Other)           -> {no_index, Other}.

%% The CBOR decoder atomises short text keys on receive while we send
%% binaries, so both sides are normalised before comparison. Without
%% this every equality check becomes a typing test rather than a
%% delivery test.
normalise_keys(Map) when is_map(Map) ->
    maps:from_list([{normalise_key(K), normalise_keys(V)}
                    || {K, V} <- maps:to_list(Map)]);
normalise_keys(List) when is_list(List) ->
    [normalise_keys(V) || V <- List];
normalise_keys(Other) ->
    Other.

normalise_key(K) when is_atom(K)   -> atom_to_binary(K, utf8);
normalise_key({text, K})           -> K;
normalise_key(K)                   -> K.
