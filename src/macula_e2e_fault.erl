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
    with_paused/2, with_stopped/2,
    set_puzzle_mode/2
]).

-type nick() :: string().

%% @doc Pause the named station (SIGSTOP-equivalent at the container
%% level — TCP / QUIC sockets remain open from the kernel's view but
%% the BEAM process makes no progress). Recovery via
%% `unpause_station/1' is instantaneous.
-spec pause_station(nick()) -> ok | {error, term()}.
pause_station(Nick) ->
    {SshHost, SshKey, Container} = host_container(Nick),
    docker_op(SshHost, SshKey, "pause", Container).

-spec unpause_station(nick()) -> ok | {error, term()}.
unpause_station(Nick) ->
    {SshHost, SshKey, Container} = host_container(Nick),
    docker_op(SshHost, SshKey, "unpause", Container).

%% @doc Stop the named station with a 1s grace window. The BEAM
%% receives SIGTERM, gets a moment to flush, then SIGKILL.
%% Recovery via `start_station/1' brings the same container back
%% up with persistent state intact.
-spec stop_station(nick()) -> ok | {error, term()}.
stop_station(Nick) ->
    {SshHost, SshKey, Container} = host_container(Nick),
    docker_op(SshHost, SshKey, "stop -t 1", Container).

-spec start_station(nick()) -> ok | {error, term()}.
start_station(Nick) ->
    {SshHost, SshKey, Container} = host_container(Nick),
    docker_op(SshHost, SshKey, "start", Container).

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

%% @doc Flip a live station's DHT-puzzle enforcement mode (`off' |
%% `log_only' | `enforce'), read fresh per handshake by
%% `macula_station_listener:puzzle_enforcement_mode/0'
%% (`application:get_env(macula_station, puzzle_enforcement, off)') --
%% no station restart needed for the flip to take effect.
%%
%% ⚠ `enforce' rejects ANY identity that predates the puzzle check,
%% which today is the fleet's own inter-station identities too --
%% flipping a station to `enforce' can disconnect it from its own
%% upstream peer, not just refuse a deliberately-unhardened test
%% connection. Never call this with `enforce' outside a round that
%% flips back to `off' in an `after' clause, same discipline as
%% `with_paused'/`with_stopped'.
-spec set_puzzle_mode(nick(), off | log_only | enforce) ->
    ok | {error, term()}.
set_puzzle_mode(Nick, Mode)
  when Mode =:= off; Mode =:= log_only; Mode =:= enforce ->
    {SshHost, SshKey, Container} = host_container(Nick),
    remote_eval(SshHost, SshKey, Container, puzzle_mode_expr(Mode)).

puzzle_mode_expr(Mode) ->
    lists:flatten(
      io_lib:format(
        "application:set_env(macula_station, puzzle_enforcement, ~p), ok.",
        [Mode])).

%%====================================================================
%% Internals
%%====================================================================

host_container(Nick) ->
    case lists:keyfind(Nick, 3, macula_e2e_fleet:stations()) of
        {_DialHost, Container, Nick} ->
            {SshHost, SshKey} = macula_e2e_fleet:ssh_target(Nick),
            {SshHost, SshKey, Container};
        false ->
            error({unknown_station, Nick})
    end.

%% Resolve the ssh reach through `macula_e2e_fleet:ssh_target/1' rather
%% than off the station tuple's dial host + a hardcoded `id_hetzner'.
%% As hardcoded, this reached only the three Hetzner boxes and silently
%% failed host-key verification on the four others — so a fault probe
%% aimed at a Linode leaf, the LOWEST-blast-radius target, was exactly
%% the one that could not run.
docker_op(SshHost, SshKey, Op, Container) ->
    Cmd =
        "ssh -i ~/.ssh/" ++ SshKey ++ " -o BatchMode=yes "
        "-o ConnectTimeout=10 root@" ++ SshHost ++ " 'docker " ++ Op ++
        " " ++ Container ++ "' 2>/dev/null",
    %% docker pause / unpause / stop / start all echo the container
    %% name on success and exit non-zero on failure. We don't get the
    %% exit code via os:cmd, so any echo that contains the container
    %% name as a standalone token is treated as success.
    Out = os:cmd(Cmd),
    docker_op_result(string:str(Out, Container), Op, Out).

docker_op_result(0, Op, Out) -> {error, {docker_op_failed, Op, Out}};
docker_op_result(_, _Op, _Out) -> ok.

%% Same ssh + explicit per-station key shape as `docker_op/4' above
%% (see its own comment on why the key cannot be resolved implicitly
%% across this fleet's boxes), reaching into the release's own `eval'
%% instead of `docker OP Container' -- the admin API is firewalled
%% from outside the box, so this is the only way to change a running
%% station's config short of a restart. Base64-encodes the expression,
%% the same reason `scripts/station-eval.sh' does for a human running
%% the equivalent by hand: it survives the remote shell's re-parsing
%% of parens and commas intact.
remote_eval(SshHost, SshKey, Container, Expr) ->
    Encoded = base64:encode(list_to_binary(Expr)),
    RemoteCmd =
        "docker exec " ++ Container ++
        " /opt/macula_station/bin/macula_station eval "
        "\"$(echo " ++ binary_to_list(Encoded) ++ " | base64 -d)\"",
    Cmd =
        "ssh -i ~/.ssh/" ++ SshKey ++ " -o BatchMode=yes "
        "-o ConnectTimeout=15 root@" ++ SshHost ++ " '" ++ RemoteCmd ++
        "' 2>/dev/null",
    Out = os:cmd(Cmd),
    remote_eval_result(Out).

%% `eval''s last statement in `puzzle_mode_expr/1' is a bare `ok', so
%% a successful flip prints exactly that. Anything else -- ssh
%% failure, a crashed eval, wrong container -- does not.
remote_eval_result(Out) ->
    case string:trim(Out) of
        "ok" -> ok;
        Other -> {error, {remote_eval_failed, Other}}
    end.
