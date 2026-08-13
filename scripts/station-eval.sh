#!/usr/bin/env bash
# Evaluate an Erlang expression inside a live station's BEAM.
#
# The station's admin port is firewalled from outside the box, so the
# only way to read a running station's internal state is through the
# release's `eval' on the box itself. This wraps that.
#
# Usage:
#   scripts/station-eval.sh <ssh-target> <container> '<erlang expr>'
#
# Example:
#   scripts/station-eval.sh root@172.232.219.239 macula-station-milan \
#     'macula_station_listener:stats(whereis(macula_station_listener)).'

set -euo pipefail

readonly SSH_TARGET="${1:?usage: station-eval.sh <ssh-target> <container> <expr>}"
readonly CONTAINER="${2:?usage: station-eval.sh <ssh-target> <container> <expr>}"
readonly EXPR="${3:?usage: station-eval.sh <ssh-target> <container> <expr>}"
readonly RELEASE_BIN="${STATION_RELEASE_BIN:-/opt/macula_station/bin/macula_station}"

# ssh joins its arguments with spaces and hands the result to a remote
# shell, so any expression containing parens, quotes or commas is
# re-parsed there. Ship it base64-encoded and decode on the far side —
# the expression then survives verbatim whatever it contains.
readonly ENCODED="$(printf '%s' "${EXPR}" | base64 -w0)"

ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_TARGET}" \
    "docker exec \"${CONTAINER}\" \"${RELEASE_BIN}\" eval \"\$(echo ${ENCODED} | base64 -d)\""
