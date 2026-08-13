#!/usr/bin/env bash
# Dial every station in macula_e2e_fleet from THIS vantage point and
# report reachability, dial latency and the node id each name answers
# with.
#
# Run this before any other probe. Everything else in this repo assumes
# the fleet is reachable and that each name is a distinct station; this
# is the only thing that checks both.
#
# Exits non-zero if any station is unreachable.
#
# Usage:
#   scripts/fleet-reach.sh
#   MACULA_E2E_FLEET='h|c|n,...' scripts/fleet-reach.sh

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EBIN_GLOB="${REPO_ROOT}/_build/default/lib/*/ebin"

cd "${REPO_ROOT}"

rebar3 compile

# shellcheck disable=SC2086
exec erl -pa ${EBIN_GLOB} -noshell -run macula_e2e_reach main
