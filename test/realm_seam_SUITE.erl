%%%-------------------------------------------------------------------
%%% @doc The realm seam: a BEAM client calls a service through a real
%%% station, authorized by a delegation a real macula-realm issued, and
%%% gets `<<"pong">>' back, on a machine that has never heard of the
%%% public fleet.
%%%
%%% == Why this is hermetic, and why nobody should "improve" it ==
%%%
%%% Two independent reasons, and the second is the one that matters.
%%%
%%% 1. It could not use the fleet even if we wanted to. GitHub-hosted
%%%    runners have no IPv6 egress and the fleet's stations are
%%%    AAAA-only, so a QUIC connect can never reach one. mcl-om's
%%%    live-mesh-tests.yml documents this in its own header: on every
%%%    push that job burned ~18 minutes for a deterministic red, which
%%%    is why it is workflow_dispatch only.
%%%
%%% 2. A gate that depends on production is not a gate. It goes red when
%%%    the fleet has a bad afternoon and green when the code is broken
%%%    but the fleet is fine. Hermetic is correct on its own merits; the
%%%    IPv6 fact merely makes it unavoidable.
%%%
%%% If a self-hosted IPv6 runner ever lands, reason 2 still stands. DO
%%% NOT point this suite at the real mesh.
%%%
%%% == ⚠ RED ON ARRIVAL, and it is the harness, not the suite ==
%%%
%%% A station spawned by `macula_station_test_cluster' fails with `undef'
%%% on `macula_quic:listen/3'. That reads as a version mismatch and is
%%% not one: `listen/3' exists in both 11.5.0 and 12. The module is not
%%% loaded AT ALL, because its `on_load' cannot find the NIF, and every
%%% function of such a module answers `undef'. The peer says so itself:
%%%
%%%   NIF load failed: '<project root>/priv/macula_quic.so:
%%%     cannot open shared object file'
%%%
%%% On the peer, `code:priv_dir(macula)' resolves to the PROJECT ROOT's
%%% `priv' rather than the build tree's. The library is present, and it
%%% loads on the node that spawns the peer. Routed to macula-station:
%%% the spawned node has to be able to resolve macula's application
%%% directory before anything touches a macula module.
%%%
%%% Until that lands, every case here that spawns a station is red.
%%%
%%% == ⚠ Two local traps that cost an hour, in case they cost you one ==
%%%
%%% 1. `rebar.lock' is GITIGNORED. A lock left over from an older build
%%%    can still pin `macula' 10.24.0 while `rebar.config' says `~> 11.4',
%%%    and the lock wins, so nothing moves and the failure is a missing
%%%    function in a module you are sure exists. `rebar3 upgrade macula'.
%%%    A fresh clone has no lock and resolves correctly, so this is local
%%%    staleness rather than a defect here.
%%% 2. The NIF `.so' from the old version is REUSED after the upgrade,
%%%    and a NIF built for another version does not load. Delete the
%%%    build directory and rebuild with `MACULA_FORCE_SOURCE_BUILD=1'.
%%%
%%% == What it asserts on ==
%%%
%%% The artefact, never a step that ran. Not exit 0, not "the harness
%%% completed", not "the service advertised", not `healthy_links > 0'
%%% (necessary, not sufficient, macula#18). And NOT `{ok, _}': that is
%%% the shape that lets a broken handler through.
%%%
%%% The full design, the ordering and the two-keys trap are in
%%% plans/DESIGN_REALM_SEAM_E2E.md. Read it before changing this file.
%%% @end
%%%-------------------------------------------------------------------
-module(realm_seam_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% The one profile this seam runs under, on every node. See 3d.
-define(PROFILE, pq_hybrid).

%% What the fleet runs, confirmed on disk per station on 2026-09-23. The station
%% falls back to `off' when the key is absent, which is the opposite, so a
%% harness that inherits the default skips the puzzle check on every inbound
%% handshake while looking green. See 3e.
-define(PUZZLE_ENFORCEMENT, enforce).

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([the_station_runs_the_profile_and_puzzle_mode_this_seam_names/1,
         a_spawned_station_serves_its_own_endpoint_record/1,
         a_published_trust_list_makes_the_realm_checkable/1,
         the_realm_loads_the_signing_key_we_published/1]).

%% Run on the station's peer node.
-export([on_station_trust_pairs/0]).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [the_station_runs_the_profile_and_puzzle_mode_this_seam_names,
     a_spawned_station_serves_its_own_endpoint_record,
     a_published_trust_list_makes_the_realm_checkable,
     the_realm_loads_the_signing_key_we_published].

init_per_suite(Config) ->
    true = absolute_code_path(),
    {ok, _} = application:ensure_all_started(macula),
    Config.

%% ⚠ Make every code path entry absolute before any station is spawned.
%%
%% `rebar3 ct' leaves RELATIVE entries in the code path (18 of 53 here: the
%% project's own `_build/test/lib/*/ebin'), and Common Test runs a case with the
%% working directory set to that run's log directory. `macula_station_test_cluster'
%% passes `code:get_path()' to `peer:start' as `-pa' arguments verbatim, so a
%% spawned station inherits those relative entries and resolves them against the
%% wrong directory.
%%
%% What that looks like is worth knowing, because it does not look like a path
%% problem: enough of the path is absolute that the peer boots and gets as far as
%% starting the station's listener, and then `macula_quic' cannot be found. A
%% module whose `on_load' cannot find its NIF is not loaded at all, so every
%% function in it answers `undef' — and the failure reads as "macula_quic:listen/3
%% does not exist", which sends you looking for a version mismatch that is not
%% there.
absolute_code_path() ->
    code:set_path([filename:absname(P) || P <- code:get_path()]).  %% true

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Name, Config) ->
    [{cluster_opts, #{base_dir => ?config(priv_dir, Config)}} | Config].

end_per_testcase(_Name, _Config) ->
    ok.

%%====================================================================
%% Step 0: the profile and the puzzle, before anything else is believed
%%====================================================================

%% @doc The station runs the profile and the puzzle mode this seam names,
%% read back FROM the station rather than assumed from what was passed.
%%
%% Neither is negotiated: every node has to be told, and two halves
%% disagreeing surfaces much later as an unverifiable chain, nowhere near
%% the cause. The harness has defaults for both, and one of them is the
%% OPPOSITE of the fleet: `macula_station_config' falls back to
%% `puzzle_enforcement = off' when the key is absent, while all six fleet
%% stations run `enforce'. A seam that inherited that default would skip
%% the puzzle check on every inbound handshake and still look green.
%%
%% This asserts the values the station actually holds, so a harness
%% default that changes underneath us fails here rather than quietly
%% moving what the seam measures.
the_station_runs_the_profile_and_puzzle_mode_this_seam_names(Config) ->
    Opts = ?config(cluster_opts, Config),
    [B] = spawn_station(Opts, mint_foundation_key()),
    try
        ?assertEqual({ok, ?PROFILE},
                     macula_station_test_cluster:rpc(
                       B, macula_crypto_profile, configured, [])),
        ?assertEqual(?PUZZLE_ENFORCEMENT,
                     macula_station_test_cluster:rpc(
                       B, application, get_env,
                       [macula_station, puzzle_enforcement, undefined])),
        %% And this node agrees with it, since the client pool that calls
        %% the service runs here.
        ?assertEqual({ok, ?PROFILE}, macula_crypto_profile:configured())
    after
        macula_station_test_cluster:stop_cluster([B])
    end.

%%====================================================================
%% Step 1 and 2 of the ordering: a station exists, and it is REALLY a
%% station.
%%====================================================================

%% @doc The foundation every other case stands on, and it is deliberately
%% not a liveness check.
%%
%% `spawn_cluster/2' returning a handle proves only that a function
%% returned. The artefact that proves a station booted is the station's
%% own `station_endpoint' record: it can only exist if the listener bound
%% a port, the identity loaded, and the DHT came up. So this reads that
%% record back and asserts its CONTENTS equal what the handle claims.
%%
%% A harness that reported a healthy station and booted nothing would
%% pass `?assertMatch({ok, _}, ...)' and fails here.
a_spawned_station_serves_its_own_endpoint_record(Config) ->
    Opts = ?config(cluster_opts, Config),
    Foundation = mint_foundation_key(),
    [B] = spawn_station(Opts, Foundation),
    try
        BPub = macula_station_test_cluster:pubkey(B),
        {_Ip, BPort} = macula_station_test_cluster:listen_addr(B),

        %% The artefact: the station's own endpoint record, read out of
        %% its DHT, naming the port it actually bound.
        %% find_local_record/2 returns a LIST. An empty one is exactly
        %% what a station that booted nothing would give, so match one
        %% record rather than accepting whatever came back.
        [Rec] = station_endpoint(B, BPub),
        #{quic_port := Port} = macula_record:read_station_endpoint(Rec),
        ?assertEqual(BPort, Port),

        %% And the foundation key id we asked for is the one it holds,
        %% so the trust-list path in the later cases has somewhere to
        %% land. Empty here would mean every advertisement takes an
        %% UNCHECKED slot place and the seam would measure the wrong
        %% path entirely.
        ?assertEqual([macula_node_keys:key_id(Foundation)],
                     macula_station_test_cluster:rpc(
                       B, macula_foundation, live_key_ids, []))
    after
        macula_station_test_cluster:stop_cluster([B])
    end.

%%====================================================================
%% Steps 3 and 4: the realm becomes checkable on this station.
%%====================================================================

%% @doc A foundation-signed trust list, PUT into the station's DHT and
%% picked up, is what makes an advertisement under our realm take a
%% CHECKED slot place instead of an unchecked one.
%%
%% Asserting that the PUT returned, or that a refresh was triggered,
%% would be asserting steps that ran. The artefact is the station's own
%% admission state: our realm id mapped to our realm signing key's key
%% id. It can only be there if the record was stored, verified against
%% the foundation key id the station was configured with, and found
%% unexpired.
%%
%% ⚠ `?TRUST_REFRESH_MS' is ONE HOUR. The PUT necessarily happens after
%% the station booted, so the refresh is forced and then READ BACK. Do
%% not replace this with a sleep.
a_published_trust_list_makes_the_realm_checkable(Config) ->
    Opts = ?config(cluster_opts, Config),
    Foundation = mint_foundation_key(),
    RealmKey = mint_realm_signing_key(),
    RealmId = <<7:256>>,
    [B] = spawn_station(Opts, Foundation),
    try
        ok = publish_trust_list(B, Foundation, RealmId, RealmKey),

        %% The artefact, and its CONTENTS: not "a trust map exists" but
        %% "our realm is mapped to our key id". A station that fetched
        %% nothing, or verified a different foundation's list, has a map
        %% that does not contain this pair.
        ?assertEqual(macula_node_keys:key_id(RealmKey),
                     trusted_key_id_for(B, RealmId))
    after
        macula_station_test_cluster:stop_cluster([B])
    end.

%%====================================================================
%% Steps 6 and 7: the realm loads OUR key, and we do not take its word.
%%====================================================================

%% @doc The realm must sign its chains with the key whose key id we put
%% in the trust list at step 3. If it signs with any other, every chain
%% it issues is unverifiable against a station that trusts us, and the
%% failure surfaces far away from its cause.
%%
%% ⛔ THE TRAP THIS EXISTS FOR. `RealmSigningKey.load_or_generate_and_cache/0'
%% is `case :macula_node_keys.load(path, :realm, profile) do {:ok, k} -> k;
%% {:error, _} -> generate_and_persist(...) end'. THE ERROR IS DISCARDED, and
%% the module logs when the SAVE fails, never when the LOAD does.
%% `macula_node_keys:load/3' refuses on key_file_permissions, bad_key_file,
%% wrong_purpose, wrong_profile and wrong_algorithms, and every one lands in
%% that silent branch. The permission gate is `Mode band 8#077 =:= 0', so the
%% file must be 0600 or 0400.
%%
%% So a realm handed a key file it cannot read BOOTS CLEAN, LOGS NOTHING, and
%% holds a different key than the one you published. This case is the design's
%% own artefact rule turned on its own scaffolding: do not trust a setup step
%% because it ran.
the_realm_loads_the_signing_key_we_published(Config) ->
    RealmKey = mint_realm_signing_key(),
    KeyPath = filename:join(?config(priv_dir, Config), "realm-key.pq.bin"),
    ok = save_realm_key(KeyPath, RealmKey),

    Realm = start_realm_node(KeyPath),
    try
        %% The artefact: the key id the REAL production module ends up
        %% holding, read out of the realm, compared with what we minted
        %% and would have published. Not "the realm started".
        ?assertEqual(macula_node_keys:key_id(RealmKey),
                     peer:call(Realm, 'Elixir.MaculaRealm.Identity.RealmSigningKey',
                               key_id, [], 30_000))
    after
        peer:stop(Realm)
    end.

%%====================================================================
%% Helpers
%%====================================================================

%% ⚠ 0600. `macula_node_keys:load/3' gates on `owner_only_read', which is
%% `Mode band 8#077 =:= 0'. A key file with default permissions is refused,
%% and RealmSigningKey turns that refusal into a silently different key.
save_realm_key(Path, Key) ->
    ok = filelib:ensure_dir(Path),
    ok = macula_node_keys:save(Path, Key),
    ok = file:change_mode(Path, 8#600).

%% A bare peer carrying macula-realm's compiled tree and Elixir's own, for
%% calling the realm's production modules. It runs no station: stations come
%% from the harness, on their own nodes.
start_realm_node(KeyPath) ->
    %% `connection => standard_io' and `peer:start', matching the station
    %% harness: the driver stays NON-DISTRIBUTED, so no net_kernel and no
    %% node-name collisions between concurrent runs. `peer:start_link' here
    %% would also tie the peer's life to the transient CT case process.
    {ok, Peer, _Node} = peer:start(
                          #{name => peer:random_name(realm_seam),
                            connection => standard_io,
                            args => ["-pa" | realm_code_path()]}),
    ok = peer:call(Peer, application, set_env, [macula, crypto_profile, profile()]),
    ok = peer:call(Peer, application, set_env, [macula_realm, realm_key_path, KeyPath]),
    {ok, _} = peer:call(Peer, application, ensure_all_started, [macula], 60_000),
    Peer.

%% macula-realm is a mix project and is not a rebar3 dependency of anything
%% here, so its tree is located rather than depended on. `MACULA_REALM_BUILD'
%% overrides for a checkout somewhere else.
realm_code_path() ->
    Build = os:getenv("MACULA_REALM_BUILD",
                      "/home/rl/work/github.com/macula-io/macula-realm/_build/test/lib"),
    Elixir = os:getenv("ELIXIR_LIB",
                       "/home/rl/.local/share/mise/installs/elixir/1.20.4-otp-28/lib"),
    filelib:wildcard(filename:join(Build, "*/ebin"))
        ++ filelib:wildcard(filename:join(Elixir, "*/ebin")).

%% Step 0 of the ordering: the REALM SIGNING key, minted by the test.
%%
%% ⛔ NOT `GuideRealmLifecycle.RealmKey'. That is `K_realm', a 256-bit
%% SYMMETRIC key for wrapping content keys; it cannot sign and has no key
%% id. The one that signs `org_directory', and whose public half every
%% pool pins, is `MaculaRealm.Identity.RealmSigningKey', which is
%% load-or-generate from a file and so can be minted here. See 3b in the
%% design; the two share a name and the wrong one is easy to reach for.
mint_realm_signing_key() ->
    {ok, K} = macula_node_keys:generate(realm, profile(), #{}),
    K.

spawn_station(Opts, Foundation) ->
    macula_station_test_cluster:spawn_cluster(
      1, Opts#{app_env => station_env([{macula, foundation_key_ids,
                                        [macula_node_keys:key_id(Foundation)]}])}).

publish_trust_list(B, Foundation, RealmId, RealmKey) ->
    Rec = macula_record:sign(
            macula_record:foundation_realm_trust_list(
              [#{realm_id => RealmId,
                 realm_key_id => macula_node_keys:key_id(RealmKey)}]),
            Foundation),
    ok = macula_station_test_cluster:rpc(
           B, macula_dht, put_record, [macula_dht, Rec]),
    force_trust_refresh(B).

%% The station reads its trust list on a ONE HOUR timer. Send the same
%% message its own timer sends, then let the next read observe the result.
force_trust_refresh(B) ->
    _ = macula_station_test_cluster:rpc(
          B, erlang, send, [macula_dht, refresh_trust_list]),
    ok.

%% The realm key id the station will admit `RealmId' under, or `none'.
%%
%% Found by searching the server's state for the map that holds the realm
%% id rather than by field position: the position is an implementation
%% detail of a record in another repo and would break on any reordering,
%% which is precisely the kind of silent rot this suite exists to catch.
trusted_key_id_for(B, RealmId) ->
    Deadline = erlang:monotonic_time(millisecond) + 5_000,
    trusted_key_id_for(B, RealmId, Deadline).

trusted_key_id_for(B, RealmId, Deadline) ->
    State = macula_station_test_cluster:rpc(
              B, sys, get_state, [macula_dht]),
    Found = [maps:get(RealmId, M)
             || M <- tuple_to_list(State), is_map(M), maps:is_key(RealmId, M)],
    retry_until(Found, B, RealmId, Deadline).

retry_until([KeyId | _], _B, _RealmId, _Deadline) ->
    KeyId;
retry_until([], B, RealmId, Deadline) ->
    still_time(erlang:monotonic_time(millisecond) < Deadline, B, RealmId, Deadline).

still_time(false, _B, _RealmId, _Deadline) ->
    none;
still_time(true, B, RealmId, Deadline) ->
    timer:sleep(100),
    trusted_key_id_for(B, RealmId, Deadline).

%% The test's own foundation key. Its key id goes on the station so a
%% realm trust list can be pinned to it later; see 3c in the design.
mint_foundation_key() ->
    {ok, K} = macula_node_keys:generate(foundation, profile(), #{}),
    K.

%% ⚠ ONE profile, named HERE as a value, set on every node and asserted. Not
%% read from the environment with a fallback: a lookup whose default equals the
%% value it is meant to find agrees with everything and catches nothing, and the
%% two halves of this seam disagreeing surfaces as an unverifiable chain far
%% from its cause. See 3d in the design.
profile() ->
    ?PROFILE.

%% The station's own `macula' and `macula_station' env, applied by the harness
%% AFTER its own defaults and before `macula' starts. It pins the profile rather
%% than inheriting the harness's, and the puzzle mode the FLEET runs rather than
%% the `off' that `macula_station_config' falls back to when the key is absent.
%% See 3d and 3e.
station_env(Extra) ->
    [{macula, crypto_profile, ?PROFILE},
     {macula_station, puzzle_enforcement, ?PUZZLE_ENFORCEMENT} | Extra].

station_endpoint(B, BPub) ->
    macula_station_test_cluster:rpc(
      B, macula_dht, find_local_record,
      [macula_dht, macula_record:station_endpoint_key(BPub)]).

%% Reads the station's admission trust pairs. Used by the later cases to
%% assert a forced refresh actually landed rather than sleeping on the
%% one-hour ?TRUST_REFRESH_MS timer.
on_station_trust_pairs() ->
    sys:get_state(macula_dht_server).
