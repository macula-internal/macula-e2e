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

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([a_spawned_station_serves_its_own_endpoint_record/1,
         a_published_trust_list_makes_the_realm_checkable/1]).

%% Run on the station's peer node.
-export([on_station_trust_pairs/0]).

suite() -> [{timetrap, {minutes, 5}}].

all() ->
    [a_spawned_station_serves_its_own_endpoint_record,
     a_published_trust_list_makes_the_realm_checkable].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(macula),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Name, Config) ->
    [{cluster_opts, #{base_dir => ?config(priv_dir, Config)}} | Config].

end_per_testcase(_Name, _Config) ->
    ok.

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
    [B] = macula_station_test_cluster:spawn_cluster(
            1, Opts#{app_env => [{macula, foundation_key_ids,
                                  [macula_node_keys:key_id(Foundation)]}]}),
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
%% Helpers
%%====================================================================

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
      1, Opts#{app_env => [{macula, foundation_key_ids,
                            [macula_node_keys:key_id(Foundation)]}]}).

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

profile() ->
    application:get_env(macula, crypto_profile, pq_hybrid).

station_endpoint(B, BPub) ->
    macula_station_test_cluster:rpc(
      B, macula_dht, find_local_record,
      [macula_dht, macula_record:station_endpoint_key(BPub)]).

%% Reads the station's admission trust pairs. Used by the later cases to
%% assert a forced refresh actually landed rather than sleeping on the
%% one-hour ?TRUST_REFRESH_MS timer.
on_station_trust_pairs() ->
    sys:get_state(macula_dht_server).
