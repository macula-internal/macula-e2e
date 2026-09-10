#!/usr/bin/env bash
# Run only the named duel rounds, between two services on the duel pair.
#
# scripts/duel.sh runs every main round. This runs just the rounds you name,
# on the same pair (macula_e2e_duel:pair/0: helsinki and nuremberg, the fleet's
# one genuine two-hop pair, unless MACULA_E2E_DUEL_PAIR is set). As in the full
# duel, distinct_stations always runs first and gates the rest. Never name a
# fault or puzzle round here: those restart a live station or flip its puzzle
# mode, and have their own entry points in macula_e2e_duel.
#
# Usage:
#   scripts/duel-rounds.sh pubsub_ordering pubsub_no_duplicates
#
# Exits non-zero if any named round fails or the services cannot start.

set -uo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SETTLE_MS=3000

[[ $# -gt 0 ]] || { sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 64; }
for round in "$@"; do
  [[ "${round}" =~ ^[a-z0-9_]+$ ]] || { echo "bad round name: ${round}" >&2; exit 64; }
done
ROUNDS="$(IFS=,; echo "$*")"
readonly ROUNDS

cd "${REPO_ROOT}"
# Honour REBAR_BASE_DIR, so a run on a different OTP can build apart from
# the default _build instead of mixing beams compiled by two releases.
readonly BUILD_DIR="${REBAR_BASE_DIR:-${REPO_ROOT}/_build}"
rebar3 compile || exit 1

# The catch-all turns a crash (a service that cannot start, a bad round name)
# into a non-zero exit. Without it `erl -noshell -eval' reports the error and
# then keeps the VM running, so the script would hang instead of failing.
# shellcheck disable=SC2086
erl -pa ${BUILD_DIR}/default/lib/*/ebin -noshell -eval "
    try
        {ok, _} = application:ensure_all_started(macula),
        {SA, SB} = macula_e2e_duel:pair(),
        RunId = integer_to_binary(erlang:system_time(second)),
        io:format(\"~n=== duel rounds ~s ===~n  a: ~s~n  b: ~s~n~n\", [RunId, SA, SB]),
        {ok, A} = macula_e2e_service:start(<<\"a\">>, SA, RunId),
        {ok, B} = macula_e2e_service:start(<<\"b\">>, SB, RunId),
        timer:sleep(${SETTLE_MS}),
        Report = macula_e2e_duel:run(A, B, [${ROUNDS}]),
        io:format(\"~s\", [macula_e2e_duel:format(Report)]),
        macula_e2e_service:stop(B),
        macula_e2e_service:stop(A),
        halt(min(1, length([R || {_, R} <- Report, R =/= ok])))
    catch
        Class:Reason:Stack ->
            io:format(\"duel-rounds crashed: ~p:~p~n~p~n\", [Class, Reason, Stack]),
            halt(2)
    end."
