%%% @doc Fleet topology — the stations this harness exercises.
%%%
%%% Single source of truth for station identity in this repo. Three
%%% other files used to carry their own copy of the list
%%% (`scripts/torture-mesh.sh', `scripts/torture-mesh-concurrent.sh',
%%% and this module's own defaults) and all three drifted onto the
%%% retired Leuven topology, which was decommissioned on 2026-07-27.
%%% The scripts now read the list from here.
%%%
%%% ⚠ **A name that resolves does not mean a station exists.** Retired
%%% station DNS was repointed at the surviving station on its box
%%% rather than deleted, so `station-be-leuven.macula.io' still
%%% resolves, still completes a QUIC handshake, and every per-station
%%% claim built on it is then fabricated. `macula_e2e_reach' exists to
%%% catch exactly that: two names answering with one node id are one
%%% station wearing two hats.
%%%
%%% Topology as deployed 2026-07-27 — ONE STATION PER BOX, seven boxes,
%%% five core in a full mesh minus the helsinki↔nuremberg edge, plus
%%% two degree-1 leaves. That missing edge is the fleet's only genuine
%%% multi-hop path among the core, so `helsinki' and `nuremberg' are
%%% the pair a two-hop torture must use. See
%%% `macula-io/macula-demo/infrastructure/FLEET.md'.
%%%
%%% Each station = `{Host, Container, NickName}':
%%% - `Host'       — ssh target, the box's address. One station per box
%%%                  means the station's own DNS name IS the box.
%%% - `Container'  — docker container name on that host
%%% - `NickName'   — short logical name used in test artifacts and the
%%%                  cross-station probe pair config
%%%
%%% Override via the `MACULA_E2E_FLEET' env var (pipe-separated triples
%%% joined by commas), e.g.:
%%%
%%%   MACULA_E2E_FLEET=host1|cntA|nickA,host2|cntB|nickB rebar3 ct ...
%%% @end
-module(macula_e2e_fleet).

-export([stations/0, names/0, domain/0, port/0,
         seed_url/1, core/0, leaves/0, two_hop_pair/0,
         ssh_target/1, print_ssh_table/0]).

-export_type([station/0, ssh_target/0]).

-type station() :: {Host :: string(),
                    Container :: string(),
                    NickName :: string()}.

%% Where a station's BOX lives for ssh, as distinct from where the
%% station DIALS. The two are not the same thing and conflating them is
%% a real trap: `station-fi-helsinki.macula.io' resolves and is the
%% dial identity, but it is not in known_hosts and its box is reached as
%% `relays-hetzner-helsinki.macula.io' with a specific key. The three
%% Hetzner boxes take `id_hetzner', frankfurt (the realm host) takes
%% `id_rsa', and the Linode boxes take `id_ed25519'. `station/0''s Host
%% field is the dial name; this is the ssh name.
-type ssh_target() :: {SshHost :: string(), SshKey :: string()}.

-define(DOMAIN, ".macula.io").
-define(PORT,   4433).

%%====================================================================
%% Topology
%%====================================================================

%% @doc Return the configured station list.
-spec stations() -> [station()].
stations() ->
    case os:getenv("MACULA_E2E_FLEET") of
        false -> default_stations();
        ""    -> default_stations();
        Spec  -> parse_spec(Spec)
    end.

%% @doc Short names of the configured stations, dial order.
-spec names() -> [string()].
names() ->
    [N || {_H, _C, N} <- stations()].

%% @doc DNS suffix every station name carries.
-spec domain() -> string().
domain() -> ?DOMAIN.

%% @doc QUIC port every station listens on.
-spec port() -> inet:port_number().
port() -> ?PORT.

%% @doc Seed URL for a station short name.
-spec seed_url(string()) -> binary().
seed_url(Station) ->
    iolist_to_binary([<<"https://">>, Station, ?DOMAIN, <<":">>,
                      integer_to_binary(?PORT)]).

%% @doc The ssh reach for a station's box: `{SshHost, SshKey}'.
%%
%% This is deliberately NOT derived from the station tuple's Host field.
%% That field is the DIAL identity (`station-fi-helsinki.macula.io'),
%% which resolves for QUIC but is not the box's ssh name and is not in
%% known_hosts. Anything that ssh'es a station — diagnostics capture,
%% fault injection — must resolve through here, or it fails
%% host-key verification on every box and picks the wrong key on the
%% four non-Hetzner ones.
-spec ssh_target(string()) -> ssh_target().
ssh_target("station-de-falkenstein") ->
    {"stations-hetzner-falkenstein.macula.io", "id_hetzner"};
ssh_target("station-fi-helsinki") ->
    {"relays-hetzner-helsinki.macula.io", "id_hetzner"};
ssh_target("station-de-nuremberg") ->
    {"relays-hetzner-nuremberg.macula.io", "id_hetzner"};
ssh_target("station-fr-paris") ->
    {"relays-linode-paris.macula.io", "id_ed25519"};
ssh_target("station-de-frankfurt") ->
    {"macula.io", "id_rsa"};
ssh_target("station-it-milan") ->
    {"172.232.219.239", "id_ed25519"};
ssh_target("station-se-stockholm") ->
    {"172.234.124.60", "id_ed25519"};
ssh_target(Other) ->
    error({no_ssh_target, Other}).

%% @doc Print one `SshHost|SshKey|Container|NickName' line per
%% configured station to stdout.
%%
%% The single source of truth for bash scripts that need the fleet
%% list. `torture-mesh.sh', `cascade-probe.sh' and
%% `conns-tab-sample.sh' used to each carry their own hand-copied
%% station array and all three drifted onto the retired Leuven
%% topology (see this module's own moduledoc) — the exact failure
%% mode a single generator closes off for good. Consumed via:
%%
%%   erl -pa .../ebin -noshell -run macula_e2e_fleet print_ssh_table
-spec print_ssh_table() -> no_return().
print_ssh_table() ->
    lists:foreach(fun print_ssh_row/1, stations()),
    halt(0).

print_ssh_row({_DialHost, Container, Nick}) ->
    {SshHost, SshKey} = ssh_target(Nick),
    io:format("~s|~s|~s|~s~n", [SshHost, SshKey, Container, Nick]).

%% @doc The five core stations. Each dials three of the other four.
-spec core() -> [string()].
core() ->
    ["station-de-falkenstein", "station-fi-helsinki",
     "station-de-nuremberg", "station-fr-paris", "station-de-frankfurt"].

%% @doc The two degree-1 leaves. Nothing dials them; milan dials only
%% paris and stockholm only helsinki. Both report `dht.size = 1' and
%% cannot see the mesh — treat any leaf-originated measurement as
%% unreliable until that is fixed.
-spec leaves() -> [string()].
leaves() ->
    ["station-it-milan", "station-se-stockholm"].

%% @doc The one station pair with no direct edge in either direction,
%% and therefore the only genuine multi-hop path among the core five.
%% A cross-station probe wired to any other pair measures one hop.
-spec two_hop_pair() -> {string(), string()}.
two_hop_pair() ->
    {"station-fi-helsinki", "station-de-nuremberg"}.

%%====================================================================
%% Internal
%%====================================================================

default_stations() ->
    [{"station-de-falkenstein" ?DOMAIN, "macula-station-falkenstein",
      "station-de-falkenstein"},
     {"station-fi-helsinki" ?DOMAIN,    "macula-station-helsinki",
      "station-fi-helsinki"},
     {"station-de-nuremberg" ?DOMAIN,   "macula-station-nuremberg",
      "station-de-nuremberg"},
     {"station-fr-paris" ?DOMAIN,       "macula-station-paris",
      "station-fr-paris"},
     {"station-de-frankfurt" ?DOMAIN,   "macula-station-frankfurt",
      "station-de-frankfurt"},
     {"station-it-milan" ?DOMAIN,       "macula-station-milan",
      "station-it-milan"},
     {"station-se-stockholm" ?DOMAIN,   "macula-station-stockholm",
      "station-se-stockholm"}].

parse_spec(Spec) ->
    [parse_triple(T) || T <- string:tokens(Spec, ",")].

parse_triple(T) ->
    case string:tokens(T, "|") of
        [H, C, N] -> {string:trim(H), string:trim(C), string:trim(N)};
        _         -> error({bad_fleet_spec, T})
    end.
