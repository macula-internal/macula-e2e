#!/usr/bin/env bash
# Witness whether a client's QUIC packets actually ARRIVE at a station.
#
# Splits the one ambiguity that a failed dial cannot resolve on its own:
#
#   packets arrive, no answer  -> the station is the problem
#   packets never arrive       -> the path is the problem
#
# Needed because ICMP is filtered across this fleet, so ping proves
# nothing, and because a station can report `healthy' to its operator
# while being unreachable from every client on the internet.
#
# Runs tcpdump on the station's box for a window, dials the station from
# HERE during that window, then prints what the far end saw.
#
# Usage:
#   scripts/station-udp-witness.sh <station-short-name> <ssh-target>
#
# Example:
#   scripts/station-udp-witness.sh station-it-milan root@172.232.219.239

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly STATION="${1:?usage: station-udp-witness.sh <station> <ssh-target>}"
readonly SSH_TARGET="${2:?usage: station-udp-witness.sh <station> <ssh-target>}"
readonly WINDOW_SECS="${WITNESS_WINDOW_SECS:-25}"
readonly QUIC_PORT="${WITNESS_QUIC_PORT:-4433}"
readonly CAPTURE="/tmp/station-udp-witness.$$"

cd "${REPO_ROOT}"

echo "=== witnessing ${STATION} on ${SSH_TARGET} for ${WINDOW_SECS}s ==="

# Capture on the far end, detached, so the local dial overlaps it.
ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_TARGET}" \
    "nohup timeout ${WINDOW_SECS} tcpdump -nn -i any -c 40 \
       udp port ${QUIC_PORT} > ${CAPTURE} 2>&1 &" \
  || { echo "could not start remote capture" >&2; exit 1; }

sleep 2

echo "--- dialling from here ---"
rebar3 compile >/dev/null
erl -pa "${REPO_ROOT}"/_build/default/lib/*/ebin -noshell \
    -eval "application:ensure_all_started(macula), \
           io:format(\"~p~n\", [macula_e2e_reach:probe(\"${STATION}\")]), \
           halt(0)." || true

echo "--- waiting out the capture window ---"
sleep "${WINDOW_SECS}"

echo "--- what the station's box saw ---"
ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_TARGET}" \
    "cat ${CAPTURE}; rm -f ${CAPTURE}"
