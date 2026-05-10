%%% @doc Fleet topology — list of stations the e2e harness exercises.
%%%
%%% Each station = `{Host, Container, NickName}':
%%% - `Host'       — ssh target (DNS hostname of the docker host)
%%% - `Container'  — docker container name on that host
%%% - `NickName'   — short logical name used in test artifacts and
%%%                  the cross-station probe pair config
%%%
%%% The Leuven 9-station partial mesh is the default. Override via
%%% the `MACULA_E2E_FLEET' env var (pipe-separated triples joined by
%%% commas), e.g.:
%%%
%%%   MACULA_E2E_FLEET=host1|cntA|nickA,host2|cntB|nickB rebar3 ct ...
%%%
%%% Mirrors the topology baked into `scripts/torture-mesh.sh' and
%%% `scripts/torture-mesh-concurrent.sh'. Keep these three in sync
%%% when the fleet changes.
-module(macula_e2e_fleet).

-export([stations/0]).

-export_type([station/0]).

-type station() :: {Host :: string(),
                    Container :: string(),
                    NickName :: string()}.

%% @doc Return the configured station list.
-spec stations() -> [station()].
stations() ->
    case os:getenv("MACULA_E2E_FLEET") of
        false -> default_stations();
        ""    -> default_stations();
        Spec  -> parse_spec(Spec)
    end.

default_stations() ->
    [{"stations-hetzner-falkenstein.macula.io", "macula-station-brussels",  "centrum"},
     {"stations-hetzner-falkenstein.macula.io", "macula-station-ghent",     "gasthuisberg"},
     {"stations-hetzner-falkenstein.macula.io", "macula-station-bertem",    "bertem"},
     {"relays-hetzner-helsinki.macula.io",      "macula-station-antwerp",   "haasrode"},
     {"relays-hetzner-helsinki.macula.io",      "macula-station-leuven",    "kessel-lo"},
     {"relays-hetzner-helsinki.macula.io",      "macula-station-linden",    "linden"},
     {"relays-hetzner-nuremberg.macula.io",     "macula-station-bruges",    "bruges"},
     {"relays-hetzner-nuremberg.macula.io",     "macula-station-hasselt",   "hasselt"},
     {"relays-hetzner-nuremberg.macula.io",     "macula-station-wijgmaal",  "wijgmaal"}].

parse_spec(Spec) ->
    [parse_triple(T) || T <- string:tokens(Spec, ",")].

parse_triple(T) ->
    case string:tokens(T, "|") of
        [H, C, N] -> {string:trim(H), string:trim(C), string:trim(N)};
        _         -> error({bad_fleet_spec, T})
    end.
