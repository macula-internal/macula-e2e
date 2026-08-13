#!/usr/bin/env bash
# Is this station actually JOINED, or does it only think it is well?
#
# Written after station-it-milan spent 30 hours in this state: container
# healthcheck green, listener alive with a clean cap, peer_observer
# holding 54 connections — and zero packets leaving the box in either
# direction. Every liveness signal a station publishes is derived from
# BEAM state that a dead transport does not disturb, so no counter ever
# disagreed with another.
#
# The three things that DID disagree with reality, and that this checks:
#
#   1. reachable   — can a client outside the box dial it at all
#   2. outbound    — a station that dials peers must HAVE an outbound
#                    conn. milan had 54 conns and 0 outbound.
#   3. verified    — connected_hostnames() must not be empty when conns
#                    are held. milan's was [].
#
# Any of those failing while the station reports healthy is the
# dead-but-healthy signature.
#
# Usage:
#   scripts/station-joined.sh <station-short-name> <ssh-target> <container>
#
# Example:
#   scripts/station-joined.sh station-it-milan root@172.232.219.239 macula-station-milan

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly STATION="${1:?usage: station-joined.sh <station> <ssh-target> <container>}"
readonly SSH_TARGET="${2:?usage: station-joined.sh <station> <ssh-target> <container>}"
readonly CONTAINER="${3:?usage: station-joined.sh <station> <ssh-target> <container>}"

readonly PROBE='O = whereis(macula_station_peer_observer),
  C = macula_station_peer_observer:conns(O),
  Out = length([X || X <- maps:values(C), maps:get(outbound, X, undefined) =/= undefined]),
  In = length([X || X <- maps:values(C), maps:get(inbound, X, undefined) =/= undefined]),
  Hosts = macula_station_peer_links:connected_hostnames(),
  L = whereis(macula_station_listener),
  {conns, maps:size(C), outbound, Out, inbound, In,
   verified, length(Hosts), listener, macula_station_listener:stats(L)}.'

cd "${REPO_ROOT}"

echo "=== ${STATION} ==="

echo "--- reachable from here ---"
rebar3 compile >/dev/null
erl -pa "${REPO_ROOT}"/_build/default/lib/*/ebin -noshell \
    -eval "application:ensure_all_started(macula), \
           R = macula_e2e_reach:probe(\"${STATION}\"), \
           io:format(\"reachable=~p healthy=~p dial_ms=~p~n\", \
                     [maps:get(reachable, R), maps:get(healthy_links, R), \
                      maps:get(dial_ms, R)]), \
           halt(0)."

echo "--- what the station believes ---"
"${REPO_ROOT}/scripts/station-eval.sh" "${SSH_TARGET}" "${CONTAINER}" "${PROBE}"
