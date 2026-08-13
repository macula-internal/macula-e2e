#!/usr/bin/env bash
# duel-fault.sh — run ONLY the fault rounds, which restart a live station.
#
# ⚠ THIS DISRUPTS THE FLEET ON PURPOSE. It stops and starts a real
# station container to prove a service survives its far station failing —
# the stated end goal of the whole harness. It is a separate script from
# duel.sh precisely so a routine duel never does this by accident.
#
# Blast radius is chosen to be minimal: it defaults service A onto
# station-se-stockholm, a degree-1 LEAF that nothing routes through, and
# pins B to that leaf's one upstream. Override the pair with
# MACULA_E2E_DUEL_PAIR="a,b" if you must, but the FIRST station is the
# one that gets stopped, so do not point it at a core station carrying
# real traffic without meaning to.
#
# The Erlang round restarts the station in an `after' clause, so a
# crashed assertion cannot leave it down. This script adds a second
# guarantee for the case Erlang cannot cover — the BEAM being killed
# from outside (a timeout, a Ctrl-C): on exit, for ANY reason, it forces
# a `docker start' of the target container.
#
# Usage:
#   scripts/duel-fault.sh
#   MACULA_E2E_DUEL_PAIR=station-it-milan,station-fr-paris scripts/duel-fault.sh

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# The first station of the pair is the one the rounds stop. Resolve its
# box + key + container so the exit trap can force it back up regardless
# of how the run ends.
readonly PAIR_SPEC="${MACULA_E2E_DUEL_PAIR:-}"
readonly TARGET_NICK="${PAIR_SPEC%%,*}"
readonly FAULT_NICK="${TARGET_NICK:-station-se-stockholm}"

declare -A SSH_HOST=(
  [station-de-falkenstein]=stations-hetzner-falkenstein.macula.io
  [station-fi-helsinki]=relays-hetzner-helsinki.macula.io
  [station-de-nuremberg]=relays-hetzner-nuremberg.macula.io
  [station-fr-paris]=relays-linode-paris.macula.io
  [station-de-frankfurt]=macula.io
  [station-it-milan]=172.232.219.239
  [station-se-stockholm]=172.234.124.60
)
declare -A SSH_KEY=(
  [station-de-falkenstein]=id_hetzner  [station-fi-helsinki]=id_hetzner
  [station-de-nuremberg]=id_hetzner    [station-fr-paris]=id_ed25519
  [station-de-frankfurt]=id_rsa        [station-it-milan]=id_ed25519
  [station-se-stockholm]=id_ed25519
)
declare -A CONTAINER=(
  [station-de-falkenstein]=macula-station-falkenstein
  [station-fi-helsinki]=macula-station-helsinki
  [station-de-nuremberg]=macula-station-nuremberg
  [station-fr-paris]=macula-station-paris
  [station-de-frankfurt]=macula-station-frankfurt
  [station-it-milan]=macula-station-milan
  [station-se-stockholm]=macula-station-stockholm
)

ensure_started() {
  local h="${SSH_HOST[$FAULT_NICK]:-}" k="${SSH_KEY[$FAULT_NICK]:-}" c="${CONTAINER[$FAULT_NICK]:-}"
  [[ -z "${h}" || -z "${c}" ]] && { echo "!! no ssh target for ${FAULT_NICK}, cannot self-heal" >&2; return; }
  echo "-- exit guard: forcing ${c} started on ${h}"
  ssh -i "${HOME}/.ssh/${k}" -o BatchMode=yes -o ConnectTimeout=15 \
      "root@${h}" "docker start ${c} 2>&1 | tail -1" || true
}
trap ensure_started EXIT

rebar3 compile >/dev/null || exit 1

# shellcheck disable=SC2086
erl -pa ${REPO_ROOT}/_build/default/lib/*/ebin -noshell -run macula_e2e_duel main_fault
