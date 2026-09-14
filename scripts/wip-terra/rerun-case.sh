#!/usr/bin/env bash
# Rerun one macula-e2e case (or the whole suite with "all") against the live
# fleet, spaced, and stop at the first failing run.
# Usage: rerun-case.sh <case|all> <first_run> <last_run> <pause_seconds>
# RUN_LABEL=<label> keeps a series' logs apart: rerun-<case>-<label>/run-N.log
set -u

CASE="${1:?case name or all}"
FIRST="${2:?first run number}"
LAST="${3:?last run number}"
PAUSE="${4:?pause seconds between runs}"
REPO="${E2E_REPO:-/home/rl/work/github.com/macula-internal/macula-e2e}"
CSV="${STATIONS_CSV:-/home/rl/work/github.com/macula-io/macula-demo/topologies/eu/stations.csv}"
OTHER_NAME="${E2E_OTHER_STATION:-nuremberg}"
OUT="$(dirname "$(readlink -f "$0")")/rerun-${OUT_NAME:-${CASE}}${RUN_LABEL:+-${RUN_LABEL}}"
mkdir -p "${OUT}"

# Same selection as macula-demo/infrastructure/beam00.lab/deploy.sh deploy_e2e.
MACULA_E2E_BOOTSTRAP="$(awk -F, 'NR > 1 && $4 == "regional" { printf "%shttps://%s:4433", (n++ ? "," : ""), $2 }' "${CSV}")"
MACULA_E2E_BOOTSTRAP_OTHER="$(awk -F, -v n="${OTHER_NAME}" 'NR > 1 && $1 == n { printf "https://%s:4433", $2 }' "${CSV}")"
export MACULA_E2E_BOOTSTRAP MACULA_E2E_BOOTSTRAP_OTHER

cd "${REPO}"
OTP="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')"
echo "case=${CASE} runs=${FIRST}..${LAST} pause=${PAUSE}s otp=${OTP} head=$(git rev-parse --short HEAD) label=${RUN_LABEL:-none}"
echo "seeds=${MACULA_E2E_BOOTSTRAP}"
echo "other=${MACULA_E2E_BOOTSTRAP_OTHER}"
echo "uncommitted:"
git diff --stat

for i in $(seq "${FIRST}" "${LAST}"); do
    start="$(date -u +%T)"
    if [ "${CASE}" = all ]; then
        rebar3 ct --suite test/macula_e2e_SUITE > "${OUT}/run-${i}.log" 2>&1
    else
        rebar3 ct --suite test/macula_e2e_SUITE --case "${CASE}" > "${OUT}/run-${i}.log" 2>&1
    fi
    rc=$?
    echo "run ${i} start ${start} end $(date -u +%T) exit ${rc}"
    if [ "${rc}" -ne 0 ]; then
        echo "ct_run=$(/usr/bin/ls -dt _build/test/ct_logs/ct_run.* | head -1)"
        sed 's/\x1b\[[0-9;]*m//g' "${OUT}/run-${i}.log" \
            | /usr/bin/grep -E -A8 '^%%% macula_e2e_SUITE ==> |^Failed [0-9]+ tests' \
            | head -80
        exit 1
    fi
    if [ "${i}" -lt "${LAST}" ]; then
        sleep "${PAUSE}"
    fi
done
echo "runs ${FIRST}..${LAST} passed"
