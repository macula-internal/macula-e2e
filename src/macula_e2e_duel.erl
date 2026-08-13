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

-export([main/0, main_fault/0, pair/0, run/2, run/3, rounds/0,
         fault_rounds/0, round_names/0, format/1]).

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
         service_survives_station_restart/2]).

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
-define(FAULT_DOWN_WAIT_MS, 60_000).
-define(FAULT_UP_WAIT_MS,  180_000).
-define(FAULT_POLL_MS,       2_000).
-define(FAULT_REPLAY_MS,    10_000).

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
     torture_sustained_pubsub].

-spec round_names() -> [atom()].
round_names() -> [distinct_stations | rounds()].

%% @doc The fault rounds — deliberately absent from `rounds/0' because
%% each one disrupts a live station and must be run on purpose, never as
%% a side effect of a routine duel.
-spec fault_rounds() -> [atom()].
fault_rounds() ->
    [service_survives_station_pause,
     service_survives_station_restart].

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
    Record   = macula_record:node_record(NodeId, [Realm], 0),
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
    Recovery = cycle_station(Station, PoolA),
    on_recovery(Recovery, PoolA, PoolB, Realm, Topic, Ref).

%% Only proceed to the fault if delivery worked first — otherwise a
%% "survives" pass would be meaningless.
on_baseline({error, Reason}, _Continue) ->
    {error, {no_delivery_before_fault, Reason}};
on_baseline(ok, Continue) ->
    Continue().

%% Stop the station, wait for the pool to notice, start it again, wait
%% for a healthy link. The `after' guarantees the start even if a wait
%% raises, so the station is never left down by a failed assertion.
cycle_station(Station, PoolA) ->
    ok = macula_e2e_fault:stop_station(Station),
    Down = try wait_link(PoolA, down, ?FAULT_DOWN_WAIT_MS)
           after catch macula_e2e_fault:start_station(Station)
           end,
    Up = wait_link(PoolA, up, ?FAULT_UP_WAIT_MS),
    {Down, Up}.

on_recovery({down, up}, PoolA, PoolB, Realm, Topic, Ref) ->
    %% Link is back; give the replay a moment to re-establish the wire
    %% subscription on the far station before testing delivery.
    timer:sleep(?FAULT_REPLAY_MS),
    R = confirm_delivery_retry(PoolB, Realm, Topic, Ref, <<"after">>, 3),
    catch macula:unsubscribe(PoolA, Ref),
    classify_restart(R);
on_recovery({timeout, _Up}, _PoolA, _PoolB, _Realm, _Topic, _Ref) ->
    {error, {link_never_dropped, the_stop_did_not_sever_the_link}};
on_recovery({down, timeout}, _PoolA, _PoolB, _Realm, _Topic, _Ref) ->
    {error, {link_never_recovered, pool_did_not_redial_after_start}}.

classify_restart(ok) ->
    ok;
classify_restart({error, Reason}) ->
    {error, {subscription_not_replayed_after_restart, Reason}}.

%% Poll the pool's health until it matches the wanted edge, or time out.
wait_link(Pool, Want, Budget) ->
    wait_link(Pool, Want, Budget, erlang:monotonic_time(millisecond)).

wait_link(Pool, Want, Budget, Start) ->
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    wait_link_step(link_edge(Pool), Want, Pool, Budget, Start, Elapsed).

wait_link_step(Want, Want, _Pool, _Budget, _Start, _Elapsed) ->
    Want;
wait_link_step(_Other, _Want, _Pool, Budget, _Start, Elapsed)
  when Elapsed >= Budget ->
    timeout;
wait_link_step(_Other, Want, Pool, Budget, Start, _Elapsed) ->
    timer:sleep(?FAULT_POLL_MS),
    wait_link(Pool, Want, Budget, Start).

link_edge(Pool) ->
    case macula:status(Pool) of
        {ok, #{healthy_links := N}} when N > 0 -> up;
        _                                      -> down
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
