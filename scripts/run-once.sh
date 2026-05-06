#!/bin/sh
# Run macula_e2e_SUITE once and exit with the test result.
#
# Designed for `docker run --rm` invocation, scheduled via
# systemd timer / cron / docker-compose-with-restart.
#
# Bootstrap URL is configurable via MACULA_E2E_BOOTSTRAP
# (comma-separated). Default https://boot.macula.io:4433.

set -e

cd /work

echo "=== macula-e2e $(date -u +%FT%TZ) ==="
echo "  bootstrap: ${MACULA_E2E_BOOTSTRAP:-https://boot.macula.io:4433 (default)}"
echo

exec rebar3 ct --suite test/macula_e2e_SUITE
