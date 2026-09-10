#!/bin/sh
# Run macula_e2e_SUITE once and exit with the test result.
#
# Designed for `docker run --rm` invocation, scheduled via
# systemd timer / cron / docker-compose-with-restart.
#
# MACULA_E2E_BOOTSTRAP (comma-separated seed URLs) is required. The suite
# fails, and this exits non-zero, when it is unset or no seed answers.
#
# The last line is always `=== macula-e2e result: PASS|FAIL (exit N)'. The
# daily beam00 run pipes this output into journald, where an exit code is
# otherwise invisible.

cd /work || exit 1

echo "=== macula-e2e $(date -u +%FT%TZ) ==="
echo "  bootstrap: ${MACULA_E2E_BOOTSTRAP:-UNSET, the suite will fail}"
echo "  bootstrap_other: ${MACULA_E2E_BOOTSTRAP_OTHER:-unset, cross_station_* cases skip}"
echo

rebar3 ct --suite test/macula_e2e_SUITE
rc=$?

if [ "$rc" -eq 0 ]; then verdict=PASS; else verdict=FAIL; fi
echo "=== macula-e2e result: $verdict (exit $rc)"
exit "$rc"
