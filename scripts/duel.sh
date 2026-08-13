#!/usr/bin/env bash
# Two services, two DIFFERENT live stations, every macula application
# primitive, under torture.
#
# Defaults to the fleet's only genuine multi-hop pair
# (macula_e2e_fleet:two_hop_pair/0 — helsinki and nuremberg, the one
# core pair with no direct edge in either direction). Any other core
# pair is a single hop while the report still reads as two.
#
# Exits non-zero if any round fails.
#
# Usage:
#   scripts/duel.sh
#   MACULA_E2E_DUEL_PAIR=station-fr-paris,station-de-falkenstein scripts/duel.sh
#
# Repeat it to soak:
#   scripts/duel.sh --rounds 10

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUNDS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rounds) ROUNDS="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

cd "${REPO_ROOT}"
rebar3 compile || exit 1

FAILED=0
for i in $(seq 1 "${ROUNDS}"); do
  [[ "${ROUNDS}" -gt 1 ]] && echo "########## iteration ${i}/${ROUNDS} ##########"
  # shellcheck disable=SC2086
  erl -pa ${REPO_ROOT}/_build/default/lib/*/ebin -noshell \
      -run macula_e2e_duel main || FAILED=$((FAILED + 1))
done

[[ "${ROUNDS}" -gt 1 ]] && echo "iterations failed: ${FAILED}/${ROUNDS}"
[[ "${FAILED}" -eq 0 ]]
