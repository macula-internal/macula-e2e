#!/usr/bin/env bash
# Concurrent variant — fire N e2e suites simultaneously to expose
# races that sequential runs miss. Each run uses a different bootstrap
# pair so different stations are exercised in parallel.

set -u

CONCURRENCY="${1:-3}"
ROUNDS="${2:-3}"

readonly PAIRS=(
  "https://station-be-leuven-centrum.macula.io:4433|https://station-be-leuven-haasrode.macula.io:4433"
  "https://station-be-leuven-gasthuisberg.macula.io:4433|https://station-be-leuven-kessel-lo.macula.io:4433"
  "https://station-be-leuven-bertem.macula.io:4433|https://station-be-leuven-linden.macula.io:4433"
  "https://station-be-bruges.macula.io:4433|https://station-be-hasselt.macula.io:4433"
)

run_one() {
  local idx="$1" round="$2" pair="$3"
  local boot="${pair%%|*}"
  local other="${pair#*|}"
  local log="/tmp/torture-conc-r${round}-i${idx}.log"
  cd "$(dirname "$0")/.."
  MACULA_E2E_BOOTSTRAP="${boot}" \
  MACULA_E2E_BOOTSTRAP_OTHER="${other}" \
  timeout 540 rebar3 ct --suite test/macula_e2e_SUITE > "${log}" 2>&1
  local result
  result=$(grep -E "^Failed [0-9]+ tests\." "${log}" | tail -1)
  echo "[r${round}-i${idx}] ${boot##*//} ↔ ${other##*//}: ${result:-NO_RESULT}"
}

for r in $(seq 1 "${ROUNDS}"); do
  echo "=== concurrent round ${r}/${ROUNDS} (${CONCURRENCY} parallel) ==="
  for i in $(seq 0 $((CONCURRENCY - 1))); do
    pair="${PAIRS[$((i % ${#PAIRS[@]}))]}"
    run_one "${i}" "${r}" "${pair}" &
  done
  wait
done

echo
echo "=== fleet snapshot ==="
PROBE='POPid=whereis(macula_station_peer_observer),{message_queue_len,Q}=process_info(POPid,message_queue_len),{memory,M}=process_info(POPid,memory),Reg=whereis(macula_remote_advertise_registry),L=length(macula_remote_advertise_registry:list(Reg)),{mbox,Q,mem_kb,M div 1024,reg,L}.'
for spec in "stations-hetzner-falkenstein.macula.io|macula-station-brussels|centrum" \
            "stations-hetzner-falkenstein.macula.io|macula-station-ghent|gasthuisberg" \
            "stations-hetzner-falkenstein.macula.io|macula-station-bertem|bertem" \
            "relays-hetzner-helsinki.macula.io|macula-station-antwerp|haasrode" \
            "relays-hetzner-helsinki.macula.io|macula-station-leuven|kessel-lo" \
            "relays-hetzner-helsinki.macula.io|macula-station-linden|linden" \
            "relays-hetzner-nuremberg.macula.io|macula-station-bruges|bruges" \
            "relays-hetzner-nuremberg.macula.io|macula-station-hasselt|hasselt" \
            "relays-hetzner-nuremberg.macula.io|macula-station-wijgmaal|wijgmaal"; do
  IFS='|' read -r host cont name <<< "${spec}"
  printf "%-15s " "${name}"
  ssh -i ~/.ssh/id_hetzner -o BatchMode=yes -o ConnectTimeout=10 \
      "root@${host}" \
      "docker exec ${cont} /opt/macula_station/bin/macula_station eval '${PROBE}'" \
    2>&1 | tail -1
done
