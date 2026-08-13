%%% @doc The ssh reach of a station is not its dial name.
%%%
%%% The 2026-08 fleet rewrite made a station tuple's Host field the DIAL
%%% identity (`station-fi-helsinki.macula.io'). Two modules —
%%% `macula_e2e_diagnostics' and `macula_e2e_fault' — used that field as
%%% an SSH host with a hardcoded `id_hetzner' key, so they failed
%%% host-key verification on every box and picked the wrong key on the
%%% four non-Hetzner ones. Both were failure-path or unused code, so
%%% nobody noticed. `ssh_target/1' is the fix; these pin it.
-module(macula_e2e_fleet_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, macula_e2e_fleet).

%% Every configured station must resolve to an ssh target, or the two
%% modules that ssh will crash the moment they touch it.
every_station_has_an_ssh_target_test() ->
    [?assertMatch({Host, Key} when is_list(Host) andalso is_list(Key),
                  ?M:ssh_target(Nick))
     || Nick <- ?M:names()].

%% The Hetzner boxes take id_hetzner; the rewrite's bug was assuming ALL
%% of them did.
hetzner_boxes_use_the_hetzner_key_test() ->
    [?assertMatch({_, "id_hetzner"}, ?M:ssh_target(N))
     || N <- ["station-de-falkenstein", "station-fi-helsinki",
              "station-de-nuremberg"]].

%% The four the bug got wrong: linode boxes on id_ed25519, the realm
%% host on id_rsa. If these ever silently revert to id_hetzner, this
%% goes red.
non_hetzner_boxes_use_their_own_keys_test() ->
    ?assertMatch({_, "id_ed25519"}, ?M:ssh_target("station-fr-paris")),
    ?assertMatch({_, "id_ed25519"}, ?M:ssh_target("station-it-milan")),
    ?assertMatch({_, "id_ed25519"}, ?M:ssh_target("station-se-stockholm")),
    ?assertMatch({_, "id_rsa"},     ?M:ssh_target("station-de-frankfurt")).

%% The ssh host is a real box name in known_hosts, NEVER the clean dial
%% name — that confusion is the whole bug. No ssh target may be the
%% station's own `.macula.io' dial name.
ssh_host_is_the_box_not_the_dial_name_test() ->
    [begin
         {SshHost, _} = ?M:ssh_target(Nick),
         ?assertNotEqual(Nick ++ ?M:domain(), SshHost)
     end || Nick <- ?M:names()].

unknown_station_is_a_loud_error_test() ->
    ?assertError({no_ssh_target, "station-xx-nowhere"},
                 ?M:ssh_target("station-xx-nowhere")).

%% The fault module must resolve a nick to {SshHost, SshKey, Container},
%% pairing the ssh target with the container name from the station tuple.
fault_resolves_ssh_and_container_test() ->
    %% Stockholm: leaf, id_ed25519, container macula-station-stockholm.
    %% Exercised through the fault module's public pause path would
    %% touch the fleet, so assert the fleet halves it composes instead.
    {SshHost, SshKey} = ?M:ssh_target("station-se-stockholm"),
    ?assertEqual("172.234.124.60", SshHost),
    ?assertEqual("id_ed25519", SshKey),
    ?assert(lists:keymember("station-se-stockholm", 3, ?M:stations())).
