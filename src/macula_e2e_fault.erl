%%% @doc Docker-level fault injection helpers for the e2e harness.
%%%
%%% Lets a probe make a station unresponsive (pause / unpause) or
%%% kill it cleanly + restart it (stop / start). The probe drives
%%% real wire-level failure modes against the live mesh — not a
%%% simulator.
%%%
%%% Fan-in to ssh + docker; no compose dependency. Pause and stop
%%% both target the existing container by name; start brings a
%%% stopped container back up. Containers are configured with
%%% restart policies in production, but those don't fire for a
%%% manual `docker stop' (intentional stop), so `start_station/1' is
%%% the explicit recovery action.
%%%
%%% Convention used by the `with_*' wrappers: the fault is applied
%%% before the function runs, the recovery action is registered
%%% with `process_flag(trap_exit, true) + after' so the station
%%% gets restored even when the probe crashes mid-test.
%%%
%%% Currently implemented:
%%%   - `pause_station/1' / `unpause_station/1'
%%%   - `stop_station/1'  / `start_station/1'
%%%   - `with_paused/2' / `with_stopped/2'
%%%
%%% Deferred (not yet useful for any committed probe):
%%%   - network-level partition via `docker network disconnect' or
%%%     iptables — adds to the wire failure surface but needs more
%%%     thought about restoration ordering and network identity.
-module(macula_e2e_fault).

-export([
    pause_station/1, unpause_station/1,
    stop_station/1, start_station/1,
    with_paused/2, with_stopped/2
]).

-type nick() :: string().

%% @doc Pause the named station (SIGSTOP-equivalent at the container
%% level — TCP / QUIC sockets remain open from the kernel's view but
%% the BEAM process makes no progress). Recovery via
%% `unpause_station/1' is instantaneous.
-spec pause_station(nick()) -> ok | {error, term()}.
pause_station(Nick) ->
    {Host, Container} = host_container(Nick),
    docker_op(Host, "pause", Container).

-spec unpause_station(nick()) -> ok | {error, term()}.
unpause_station(Nick) ->
    {Host, Container} = host_container(Nick),
    docker_op(Host, "unpause", Container).

%% @doc Stop the named station with a 1s grace window. The BEAM
%% receives SIGTERM, gets a moment to flush, then SIGKILL.
%% Recovery via `start_station/1' brings the same container back
%% up with persistent state intact.
-spec stop_station(nick()) -> ok | {error, term()}.
stop_station(Nick) ->
    {Host, Container} = host_container(Nick),
    docker_op(Host, "stop -t 1", Container).

-spec start_station(nick()) -> ok | {error, term()}.
start_station(Nick) ->
    {Host, Container} = host_container(Nick),
    docker_op(Host, "start", Container).

%% @doc Run `Fun' while the named station is paused. Restoration is
%% registered with `try ... after' so the station always returns to
%% the unpaused state, even if the probe crashes mid-test.
-spec with_paused(nick(), fun(() -> Result)) -> Result.
with_paused(Nick, Fun) ->
    ok = pause_station(Nick),
    try Fun()
    after _ = unpause_station(Nick)
    end.

%% @doc Run `Fun' while the named station is stopped. Restoration
%% via `start_station/1'. Note that `start' takes longer than
%% `unpause' (the BEAM cold-starts), so probes using this should
%% include a settle delay before asserting recovery.
-spec with_stopped(nick(), fun(() -> Result)) -> Result.
with_stopped(Nick, Fun) ->
    ok = stop_station(Nick),
    try Fun()
    after _ = start_station(Nick)
    end.

%%====================================================================
%% Internals
%%====================================================================

host_container(Nick) ->
    case lists:keyfind(Nick, 3, macula_e2e_fleet:stations()) of
        {Host, Container, Nick} -> {Host, Container};
        false -> error({unknown_station, Nick})
    end.

docker_op(Host, Op, Container) ->
    Cmd =
        "ssh -i ~/.ssh/id_hetzner -o BatchMode=yes -o ConnectTimeout=10 "
        "root@" ++ Host ++ " 'docker " ++ Op ++ " " ++ Container ++
        "' 2>/dev/null",
    case os:cmd(Cmd) of
        Out when is_list(Out) ->
            %% docker pause / unpause / stop / start all echo the
            %% container name on success and exit non-zero on
            %% failure. We don't get the exit code via os:cmd, so
            %% any echo that contains the container name as a
            %% standalone token is treated as success.
            case string:str(Out, Container) of
                0 -> {error, {docker_op_failed, Op, Out}};
                _ -> ok
            end
    end.
