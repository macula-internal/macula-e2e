#!/usr/bin/env bash
# macula-portal#89: the tube channel page's eight thumbnails, at once.
#
# Runs the CT case that fires the page's real MCIDs at the real mcl-tube from
# ONE pool, with io.macula's realm key pinned, each reply verified against the
# SHA-384 id it asked for. Green means every thumbnail answered inside the
# portal's own 5 s deadline.
#
# ⛔ NOT in CI, deliberately. The stations are AAAA-only and GitHub-hosted
# runners have no IPv6 egress; this repository is PUBLIC, so no self-hosted
# runner may take work from it either. Run it from host00, by hand:
#
#   * before a portal release, and after any station release or fleet move;
#   * whenever someone reports a thumbnail that does not render.
#
# macula 16 refuses a seed that does not name the node id it expects, so a
# seed is https://host:port#<64 hex node id> — the ids are mcl-stations'
# own list_stations. No seed is baked in here: a public repo is not the
# place to pin one station, and the caller knows which pair it wants.
#
# Usage:
#   MACULA_E2E_BOOTSTRAP='https://host:4433#<node id>' \
#     [MACULA_E2E_BOOTSTRAP_OTHER='https://host:4433#<node id>'] \
#     scripts/run-page-burst.sh
#
# MACULA_E2E_BOOTSTRAP_OTHER adds the second pool: the same page dialed
# through a station in another part of the federation. Without it the
# cross-station case is skipped by CT, not failed.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${SUITE:-test/macula_e2e_SUITE}"
CASES="${CASES:-page_burst,cross_station_page_burst}"

[ -n "${MACULA_E2E_BOOTSTRAP:-}" ] || {
  echo "set MACULA_E2E_BOOTSTRAP to https://host:4433#<64 hex node id>" >&2
  exit 1
}

cd "$HERE"
exec rebar3 ct --suite "$SUITE" --case "$CASES"
