#!/usr/bin/env bash
# Run N e2e iterations against the real fleet's two-hop pair
# (station-fi-helsinki <-> station-de-nuremberg, the one core pair
# with no direct edge — see macula_e2e_fleet:two_hop_pair/0),
# sampling `conns_tab' on every station between iterations. Surfaces
# accumulation per iteration so the cascade pattern is visible
# without parsing CT output.
#
# Complementary to `torture-mesh.sh' (which records pass/fail counts
# in a CSV and detects cascade timing). This script focuses on the
# substrate-state samples between runs.
#
# Usage:
#   ./scripts/cascade-probe.sh           # 5 iterations
#   ./scripts/cascade-probe.sh 4         # 4 iterations

set -u
N="${1:-5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="/tmp/cascade-probe-$(date +%s).log"
echo "log: $LOG"

cd "${HERE}/.."

"${HERE}/conns-tab-sample.sh" "iter-0-pre" | tee -a "$LOG"

for i in $(seq 1 "$N"); do
  echo "=== iteration $i ===" | tee -a "$LOG"
  start=$(date +%s)
  MACULA_E2E_BOOTSTRAP="https://station-fi-helsinki.macula.io:4433" \
  MACULA_E2E_BOOTSTRAP_OTHER="https://station-de-nuremberg.macula.io:4433" \
  timeout 540 rebar3 ct --suite test/macula_e2e_SUITE 2>&1 \
    | grep -E "Failed|Passed|Skipped" \
    | tail -1 \
    | tee -a "$LOG"
  end=$(date +%s)
  echo "iter $i duration: $((end - start))s" | tee -a "$LOG"
  "${HERE}/conns-tab-sample.sh" "iter-$i-post" | tee -a "$LOG"
done

echo "log: $LOG"
