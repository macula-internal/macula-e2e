#!/usr/bin/env bash
# Stress-run the e2e suite against the Leuven cross-station topology.
# Two modes:
#   - rounds mode (default): run N suite iterations back-to-back
#   - soak mode (--duration M): loop suite iterations until M minutes elapsed
#
# Per iteration, parses the CT output for pass / fail counts + failed case
# names, appends a row to a CSV. At end, reports iteration count, total
# wall-clock time, first-cascade marker (first iteration whose result
# diverged from the first iteration's), and per-case failure frequency.
#
# A pre/post BEAM-state snapshot brackets the run so the operator can
# eyeball mailbox / memory drift across the whole soak.
#
# Usage:
#   torture-mesh.sh                         # 5 rounds
#   torture-mesh.sh 10                      # 10 rounds (legacy positional)
#   torture-mesh.sh --rounds 10
#   torture-mesh.sh --duration 60           # soak 60 minutes
#   torture-mesh.sh --duration 60 --csv /tmp/soak.csv
#
# CSV columns:
#   iteration,start_unix,duration_sec,pass,fail,exit_code,failed_cases
# `failed_cases' is a semicolon-joined list (CT case names) or empty.

set -u

ROUNDS=""
DURATION_MIN=""
CSV=""
LEGACY_ROUNDS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rounds)   ROUNDS="$2"; shift 2 ;;
    --duration) DURATION_MIN="$2"; shift 2 ;;
    --csv)      CSV="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      # Positional fallback for legacy `torture-mesh.sh 10` form.
      if [[ -z "${LEGACY_ROUNDS}" && "$1" =~ ^[0-9]+$ ]]; then
        LEGACY_ROUNDS="$1"
        shift
      else
        echo "unknown arg: $1" >&2
        exit 1
      fi
      ;;
  esac
done

# Resolve mode + defaults.
if [[ -n "${DURATION_MIN}" ]]; then
  MODE="soak"
elif [[ -n "${ROUNDS}" ]]; then
  MODE="rounds"
elif [[ -n "${LEGACY_ROUNDS}" ]]; then
  MODE="rounds"
  ROUNDS="${LEGACY_ROUNDS}"
else
  MODE="rounds"
  ROUNDS="5"
fi

STAMP="$(date +%s)"
LOG="/tmp/torture-mesh-${STAMP}.log"
CSV="${CSV:-/tmp/torture-mesh-${STAMP}.csv}"

readonly STATIONS=(
  "stations-hetzner-falkenstein.macula.io|macula-station-brussels|centrum"
  "stations-hetzner-falkenstein.macula.io|macula-station-ghent|gasthuisberg"
  "stations-hetzner-falkenstein.macula.io|macula-station-bertem|bertem"
  "relays-hetzner-helsinki.macula.io|macula-station-antwerp|haasrode"
  "relays-hetzner-helsinki.macula.io|macula-station-leuven|kessel-lo"
  "relays-hetzner-helsinki.macula.io|macula-station-linden|linden"
  "relays-hetzner-nuremberg.macula.io|macula-station-bruges|bruges"
  "relays-hetzner-nuremberg.macula.io|macula-station-hasselt|hasselt"
  "relays-hetzner-nuremberg.macula.io|macula-station-wijgmaal|wijgmaal"
)

PROBE='POPid=whereis(macula_station_peer_observer),{message_queue_len,Q}=process_info(POPid,message_queue_len),{memory,M}=process_info(POPid,memory),Reg=whereis(macula_remote_advertise_registry),L=length(macula_remote_advertise_registry:list(Reg)),{mbox,Q,mem_kb,M div 1024,reg,L}.'

snapshot() {
  local label="$1"
  echo "=== ${label} ===" | tee -a "${LOG}"
  for spec in "${STATIONS[@]}"; do
    local host="${spec%%|*}"
    local rest="${spec#*|}"
    local cont="${rest%%|*}"
    local name="${rest#*|}"
    printf "%-15s " "${name}" | tee -a "${LOG}"
    ssh -i ~/.ssh/id_hetzner -o BatchMode=yes -o ConnectTimeout=10 \
        "root@${host}" \
        "docker exec ${cont} /opt/macula_station/bin/macula_station eval '${PROBE}'" \
      2>&1 | tail -1 | tee -a "${LOG}"
  done
}

# Run one iteration. Captures output, parses pass/fail counts + failed
# case names, appends a CSV row. Echoes a one-line per-iteration summary
# to the log.
run_iteration() {
  local n="$1"
  local started_at
  started_at="$(date +%s)"
  local out_file
  out_file="$(mktemp)"
  echo | tee -a "${LOG}"
  echo "=== iter ${n} @ $(date +%H:%M:%S) ===" | tee -a "${LOG}"

  cd "$(dirname "$0")/.."
  MACULA_E2E_BOOTSTRAP="https://station-be-leuven-centrum.macula.io:4433" \
  MACULA_E2E_BOOTSTRAP_OTHER="https://station-be-leuven-haasrode.macula.io:4433" \
  timeout 540 rebar3 ct --suite test/macula_e2e_SUITE > "${out_file}" 2>&1
  local exit_code=$?

  local now
  now="$(date +%s)"
  local duration=$((now - started_at))

  # Parse the CT trailing summary. Three shapes seen in practice:
  #   "Failed N tests. Passed M tests."    -> pass=M fail=N
  #   "Skipped N (N, 0) tests. Passed M tests."  -> fleet unreachable
  #     -> pass=M fail=N (skipped counted as failures for cascade detection)
  #   "All N tests passed."                -> pass=N fail=0
  local pass fail
  read -r pass fail <<< "$(awk '
    /Failed [0-9]+ tests\. Passed [0-9]+ tests\./ {
      for (i = 1; i <= NF; i++) {
        if ($i == "Failed") f = $(i+1)
        if ($i == "Passed") p = $(i+1)
      }
    }
    /Skipped [0-9]+ .* tests\. Passed [0-9]+ tests\./ {
      for (i = 1; i <= NF; i++) {
        if ($i == "Skipped") f = $(i+1)
        if ($i == "Passed")  p = $(i+1)
      }
    }
    /^All [0-9]+ tests passed\./ {
      p = $2
      f = 0
    }
    END { printf "%s %s\n", (p == "" ? 0 : p), (f == "" ? 0 : f) }
  ' "${out_file}")"

  # Parse failed/skipped case names from `==> <case>: FAILED|SKIPPED'
  # lines. Skipped is treated like failed for cascade-detection purposes
  # (fleet-unreachable mass-skip is itself the failure mode we want to
  # detect, not a healthy state). CT colours its output with ANSI
  # escapes (\x1b[...m) which we strip first so the case-name regex
  # matches cleanly.
  local failed_cases
  failed_cases="$(sed -E $'s/\x1b\\[[0-9;]*m//g' "${out_file}" \
    | grep -oE '==> [a-z_]+: (FAILED|SKIPPED)' \
    | sed -E 's/==> ([a-z_]+):.*/\1/' \
    | sort -u \
    | tr '\n' ';' \
    | sed 's/;$//')"

  # Echo the summary line we'd have shown in legacy mode.
  grep -E "FAILED|Failed|Passed" "${out_file}" | tee -a "${LOG}" >/dev/null
  printf "iter=%s pass=%s fail=%s dur=%ss exit=%s%s\n" \
    "${n}" "${pass}" "${fail}" "${duration}" "${exit_code}" \
    "${failed_cases:+ failed=${failed_cases}}" \
    | tee -a "${LOG}"

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "${n}" "${started_at}" "${duration}" "${pass}" "${fail}" \
    "${exit_code}" "${failed_cases}" \
    >> "${CSV}"

  rm -f "${out_file}"
}

# Decide whether the loop should continue (returns 0 = continue, 1 = stop).
should_continue() {
  local n="$1"
  if [[ "${MODE}" == "soak" ]]; then
    local elapsed=$(( $(date +%s) - START_TIME ))
    local cap=$(( DURATION_MIN * 60 ))
    [[ "${elapsed}" -lt "${cap}" ]]
  else
    [[ "${n}" -le "${ROUNDS}" ]]
  fi
}

# Identify the first iteration whose failure-set differs from iter 1's.
# Empty iter-1 failure-set + non-empty iter K = cascade @ K (the
# interesting case: green baseline, regression after some load).
# Iter 1 already non-empty = substrate was broken from the first iteration
# (no green baseline, often "fleet_not_reachable" mass-skip after prior
# cascade). Reports "always-failing" in that case.
detect_first_cascade() {
  awk -F, '
    NR == 1 { next }   # header
    NR == 2 {
      baseline = $7
      if (baseline != "") {
        verdict = "always-failing (no green baseline)"
        exit
      }
      next
    }
    $7 != baseline {
      verdict = $1
      exit
    }
    END {
      if (verdict != "")  print verdict
      else if (NR < 2)    print "n/a"
      else                print "no cascade"
    }
  ' "${CSV}"
}

# Print per-case failure frequency across the run.
case_frequency() {
  awk -F, '
    NR == 1 { next }
    $7 != "" {
      n = split($7, a, ";")
      for (i = 1; i <= n; i++) freq[a[i]]++
    }
    END {
      for (c in freq) printf "%4d  %s\n", freq[c], c
    }
  ' "${CSV}" | sort -rn
}

#--- main -------------------------------------------------------------

echo "torture log: ${LOG}" | tee "${LOG}"
echo "torture csv: ${CSV}" | tee -a "${LOG}"
echo "mode       : ${MODE}" | tee -a "${LOG}"
if [[ "${MODE}" == "soak" ]]; then
  echo "duration   : ${DURATION_MIN} min" | tee -a "${LOG}"
else
  echo "rounds     : ${ROUNDS}" | tee -a "${LOG}"
fi

printf 'iteration,start_unix,duration_sec,pass,fail,exit_code,failed_cases\n' \
  > "${CSV}"

snapshot "PRE-TORTURE"

START_TIME="$(date +%s)"
ITER=1
while should_continue "${ITER}"; do
  run_iteration "${ITER}"
  ITER=$((ITER + 1))
done

snapshot "POST-TORTURE"

echo | tee -a "${LOG}"
echo "=== run summary ===" | tee -a "${LOG}"
TOTAL_ITERS=$((ITER - 1))
ELAPSED=$(( $(date +%s) - START_TIME ))
echo "iterations    : ${TOTAL_ITERS}" | tee -a "${LOG}"
echo "elapsed_sec   : ${ELAPSED}" | tee -a "${LOG}"
echo "first_cascade : iter $(detect_first_cascade)" | tee -a "${LOG}"
echo "case freq     :" | tee -a "${LOG}"
case_frequency | tee -a "${LOG}"
echo | tee -a "${LOG}"
echo "log: ${LOG}" | tee -a "${LOG}"
echo "csv: ${CSV}" | tee -a "${LOG}"
