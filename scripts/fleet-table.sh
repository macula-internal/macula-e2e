#!/usr/bin/env bash
# Print one `SshHost|SshKey|Container|NickName' line per configured
# station. Single source of truth is `macula_e2e_fleet:print_ssh_table/0'
# — scripts that need the fleet list should read it from here rather
# than hardcoding their own copy, which is exactly how torture-mesh.sh,
# cascade-probe.sh and conns-tab-sample.sh drifted onto the retired
# Leuven topology after it was decommissioned 2026-07-27.
#
# Usage:
#   scripts/fleet-table.sh
#   while IFS='|' read -r ssh_host ssh_key container nick; do ...
#     done < <(scripts/fleet-table.sh)

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EBIN_GLOB="${REPO_ROOT}/_build/default/lib/*/ebin"

cd "${REPO_ROOT}"
rebar3 compile >/dev/null

# shellcheck disable=SC2086
erl -pa ${EBIN_GLOB} -noshell -run macula_e2e_fleet print_ssh_table
