#!/bin/sh
# Run macula_e2e_SUITE once and exit with the test result.
#
# Designed for `docker run --rm` invocation, scheduled via
# systemd timer / cron / docker-compose-with-restart.
#
# MACULA_E2E_BOOTSTRAP (comma-separated seed URLs) is required. The suite
# fails, and this exits non-zero, when it is unset or no seed answers.

set -e

cd /work

echo "=== macula-e2e $(date -u +%FT%TZ) ==="
echo "  bootstrap: ${MACULA_E2E_BOOTSTRAP:-UNSET, the suite will fail}"
echo

exec rebar3 ct --suite test/macula_e2e_SUITE
