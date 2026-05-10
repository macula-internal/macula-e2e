%%% @doc Per-test diagnostic capture for the e2e harness.
%%%
%%% The motivation: when a probe fails, knowing which case failed and
%%% the assertion message is rarely enough. We want the per-station
%%% logs that span the test's window plus a snapshot of each station's
%%% BEAM state at failure time, all attached to the CT case directory
%%% as artefacts. Lets the next investigation start with data instead
%%% of `docker logs | wc -l`.
%%%
%%% Hooked from `init_per_testcase' / `end_per_testcase' in
%%% `macula_e2e_SUITE'. Capture is timestamped at probe start; the
%%% expensive ssh fetches happen only when the probe FAILS, keeping
%%% the green path fast (about a millisecond per probe).
%%%
%%% Artefacts dropped under the CT case `priv_dir':
%%% - `<nick>_logs.txt'   — `docker logs --since <test_duration>' per station
%%% - `<nick>_state.txt'  — multi-query BEAM snapshot per station
%%% - `summary.txt'       — pass/fail + reason + duration + station list
-module(macula_e2e_diagnostics).

-export([
    start_capture/1,
    stop_capture/4
]).

-export_type([handle/0]).

-opaque handle() :: #{
    started_at := integer(),         %% erlang:system_time(second)
    stations   := [macula_e2e_fleet:station()]
}.

%% @doc Open a capture window. Cheap — just records the start
%% timestamp and the station list. Call this from
%% `init_per_testcase'.
-spec start_capture([macula_e2e_fleet:station()]) -> handle().
start_capture(Stations) ->
    #{started_at => erlang:system_time(second),
      stations   => Stations}.

%% @doc Close a capture window. On `ok' (test passed), no fetch is
%% performed; the start timestamp is discarded. On any other status,
%% the fetch happens in parallel across all stations and the
%% per-station log windows + BEAM state snapshots are saved under
%% `PrivDir/diag-<testcase>/'. Call this from `end_per_testcase'.
%%
%% `TestCase' is the testcase atom from `end_per_testcase/2'; we
%% scope artefacts under it because CT shares one `priv_dir' across
%% the whole suite — without scoping, every failing case overwrites
%% the previous case's bundle.
%%
%% `Status' is the value of `?config(tc_status, Config)' from CT
%% (`ok', `{failed, Reason}', `{skipped, Reason}', or undefined when
%% CT didn't populate the field).
-spec stop_capture(handle(), TestCase :: atom(), Status :: term(),
                   PrivDir :: file:filename_all()) -> ok.
stop_capture(_Handle, _TestCase, ok, _PrivDir) ->
    ok;
stop_capture(#{started_at := StartedAt, stations := Stations},
             TestCase, Status, PrivDir) ->
    Now      = erlang:system_time(second),
    Duration = max(1, Now - StartedAt),
    Since    = integer_to_list(Duration + 5) ++ "s",
    BundleDir = filename:join(PrivDir,
                              "diag-" ++ atom_to_list(TestCase)),
    ok = filelib:ensure_dir(filename:join(BundleDir, "x")),
    write_summary(BundleDir, Status, Duration, Stations),
    Tasks = [{logs,  Stations, Since},
             {state, Stations, undefined}],
    parallel_collect(Tasks, BundleDir),
    ok.

%%====================================================================
%% Internal — summary
%%====================================================================

write_summary(PrivDir, Status, DurationSec, Stations) ->
    Path  = filename:join(PrivDir, "summary.txt"),
    Lines = [
        io_lib:format("status         : ~p~n",       [Status]),
        io_lib:format("duration_sec   : ~p~n",       [DurationSec]),
        io_lib:format("captured_at    : ~p~n",       [calendar:universal_time()]),
        io_lib:format("station_count  : ~p~n",       [length(Stations)]),
        io_lib:format("stations       : ~p~n",       [Stations])
    ],
    file:write_file(Path, Lines).

%%====================================================================
%% Internal — parallel ssh fan-out
%%====================================================================

parallel_collect(Tasks, PrivDir) ->
    Pids = [spawn_task(Task, PrivDir, self()) || Task <- expand_tasks(Tasks)],
    gather(Pids).

expand_tasks([]) -> [];
expand_tasks([{logs, Stations, Since} | Rest]) ->
    [{log_fetch, S, Since} || S <- Stations] ++ expand_tasks(Rest);
expand_tasks([{state, Stations, _} | Rest]) ->
    [{state_dump, S} || S <- Stations] ++ expand_tasks(Rest).

spawn_task(Task, PrivDir, Parent) ->
    spawn_link(fun() ->
        run_task(Task, PrivDir),
        Parent ! {done, self()}
    end).

gather([]) -> ok;
gather(Pids) ->
    receive
        {done, Pid} -> gather(lists:delete(Pid, Pids))
    after 60_000 ->
        %% Don't let a hung ssh wedge end_per_testcase forever; the
        %% remaining captures just won't appear in priv_dir.
        ok
    end.

%%====================================================================
%% Internal — ssh fetch + BEAM eval
%%====================================================================

run_task({log_fetch, {Host, Container, Nick}, Since}, PrivDir) ->
    OutPath = filename:join(PrivDir, Nick ++ "_logs.txt"),
    Cmd =
        ssh_prefix() ++ Host ++
        " 'docker logs --since " ++ Since ++ " " ++ Container ++
        " 2>&1' > " ++ OutPath ++ " 2>/dev/null",
    _ = os:cmd(Cmd),
    ok;
run_task({state_dump, {Host, Container, Nick}}, PrivDir) ->
    OutPath = filename:join(PrivDir, Nick ++ "_state.txt"),
    Cmd =
        ssh_prefix() ++ Host ++
        " \"docker exec " ++ Container ++
        " /opt/macula_station/bin/macula_station eval '" ++ eval_expr() ++ "'\""
        " > " ++ OutPath ++ " 2>&1",
    _ = os:cmd(Cmd),
    ok.

ssh_prefix() ->
    "ssh -i ~/.ssh/id_hetzner -o BatchMode=yes -o ConnectTimeout=10 root@".

%% Multi-query BEAM snapshot. One `eval' call per station to avoid
%% N round-trips. Returns a printable proplist; the release's `eval'
%% command prints whatever the expression evaluates to.
%%
%% No string literals (`"..."') in the expression on purpose — they
%% would collide with the bash double quotes wrapping the
%% `docker exec' arg. A proplist of atoms+integers+undefined needs
%% no embedded quotes.
%%
%% Each query is wrapped in a `try' to keep one missing process from
%% blanking the whole snapshot. Adjust the query set as new
%% diagnostic signals become useful.
eval_expr() ->
    "Vsn = element(2, application:get_key(macula, vsn)),"
    "Procs = erlang:system_info(process_count),"
    "PObsQ = try element(2, lists:keyfind(message_queue_len, 1,"
        " process_info(whereis(macula_station_peer_observer), [message_queue_len])))"
        " catch _:_ -> undefined end,"
    "PObsHeap = try element(2, lists:keyfind(total_heap_size, 1,"
        " process_info(whereis(macula_station_peer_observer), [total_heap_size])))"
        " catch _:_ -> undefined end,"
    "Blooms = try maps:size(macula_station_bloom_exchange:peer_blooms("
        " whereis(macula_station_bloom_exchange))) catch _:_ -> undefined end,"
    "Links = try length(supervisor:which_children("
        " whereis(macula_station_outbound_links_sup))) catch _:_ -> undefined end,"
    "ConnsTab = try ets:info(macula_station_peer_observer_conns, size)"
        " catch _:_ -> undefined end,"
    "[{vsn, Vsn}, {procs, Procs}, {peer_obs_q, PObsQ},"
    " {peer_obs_heap, PObsHeap}, {blooms, Blooms}, {links, Links},"
    " {conns_tab, ConnsTab}].".
