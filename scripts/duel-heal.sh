#!/usr/bin/env bash
# duel-heal.sh — verify the advertise-reconcile fix on the two-hop pair.
#
# Runs the re-advertise heal round N times against helsinki<->nuremberg
# (the one core pair with no direct edge). Each run: advertise, confirm
# cross-hop call works, unadvertise, re-advertise, then POLL the call for
# ~50s.
#
# The discriminator is across runs, not within one:
#   - Before the fix, a wedged re-advertise was PERMANENT, so the 50s
#     poll still failed on roughly half the runs.
#   - After the fix, a wedge self-heals on the next ~30s reconcile, so
#     every run passes.
#
# So: several runs with ZERO failures is the pass. One run proves little.
#
# Usage:
#   scripts/duel-heal.sh            # 6 runs
#   scripts/duel-heal.sh 10

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RUNS="${1:-6}"
cd "${REPO_ROOT}"

rebar3 compile >/dev/null || exit 1

fail=0
for i in $(seq 1 "${RUNS}"); do
  echo "########## heal run ${i}/${RUNS} ##########"
  # shellcheck disable=SC2086
  if erl -pa ${REPO_ROOT}/_build/default/lib/*/ebin -noshell \
         -run macula_e2e_duel main_heal; then
    echo "  -> PASS"
  else
    echo "  -> FAIL"
    fail=$((fail + 1))
  fi
done

echo
echo "heal runs failed: ${fail}/${RUNS}"
[ "${fail}" -eq 0 ]
