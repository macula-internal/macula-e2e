#!/usr/bin/env bash
# duel-puzzle.sh — run ONLY the DHT-puzzle rounds, which flip a live
# station's puzzle enforcement mode to `enforce'.
#
# ⚠ THIS DISRUPTS THE FLEET ON PURPOSE. `enforce' rejects ANY identity
# that predates the puzzle check, which today is the fleet's own
# inter-station identities too -- flipping a station to `enforce' can
# disconnect it from its own upstream peer, not just refuse this
# round's deliberately-unhardened test connection.
#
# The Erlang round reverts to `off' in an `after' clause, but that
# clause's own revert call can itself fail silently -- confirmed live
# 2026-08-27, when exactly that happened and left station-se-stockholm
# stuck in `enforce' with no indication in the report. This script adds
# the same second guarantee `duel-fault.sh' has for its own fault
# rounds: on exit, for ANY reason, force the mode back to `off' from
# outside the BEAM.
#
# Defaults to the same leaf-first pair as duel-fault.sh -- stockholm is
# a degree-1 LEAF that nothing routes through, so its config flip
# affects nothing else. Override with MACULA_E2E_DUEL_PAIR="a,b" like
# the others, but the FIRST station is the one whose mode gets flipped.
#
# Usage:
#   scripts/duel-puzzle.sh
#   MACULA_E2E_DUEL_PAIR=station-it-milan,station-fr-paris scripts/duel-puzzle.sh

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly PAIR_SPEC="${MACULA_E2E_DUEL_PAIR:-}"
readonly TARGET_NICK="${PAIR_SPEC%%,*}"
readonly FAULT_NICK="${TARGET_NICK:-station-se-stockholm}"

ensure_off() {
  echo "-- exit guard: forcing ${FAULT_NICK} puzzle_enforcement back to 'off'"
  "${REPO_ROOT}/scripts/station-eval.sh" \
    "$(fleet_ssh_target)" \
    "$(fleet_container)" \
    'application:set_env(macula_station, puzzle_enforcement, off), ok.' \
    2>&1 | tail -1 || true
}

# Resolve this station's ssh target + container via the same fleet
# table every other script reads from, not a hand-copied lookup.
fleet_row() {
  "${REPO_ROOT}/scripts/fleet-table.sh" | awk -F'|' -v n="${FAULT_NICK}" '$4==n {print; found=1} END {if (!found) exit 1}'
}
fleet_ssh_target() { fleet_row | awk -F'|' '{print "root@"$1}'; }
fleet_container()  { fleet_row | awk -F'|' '{print $3}'; }

trap ensure_off EXIT

rebar3 compile >/dev/null || exit 1

# shellcheck disable=SC2086
erl -pa ${REPO_ROOT}/_build/default/lib/*/ebin -noshell -run macula_e2e_duel main_puzzle
