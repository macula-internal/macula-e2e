#!/usr/bin/env bash
# xref over the TEST beams.
#
# `rebar3 xref' analyses the default profile, so it never sees `test/'. A suite
# that calls a function which no longer exists therefore compiles, passes lint,
# passes eunit, passes xref — and fails only when the case finally runs. That is
# the rot of macula-internal/macula-e2e#1, and the CT suite is the one thing CI
# cannot run here (the fleet is AAAA-only). This is the check that covers it.
#
# Every beam on the code path is given to xref as a library, deps and OTP
# included, so a call is reported only when this project cannot satisfy it.
#
# ⛔ `seam/' is NOT covered: its dependencies are private (macula-station), so
# they are not on the default profile's path and every call would read as
# undefined. It runs where that source is readable, by hand.
#
#   scripts/xref-test-beams.sh      # exit 1 and the findings, if any
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# Compiled from scratch every run: rebar3 skips a suite whose beam is newer
# than its source, and a stale beam is precisely the false green this check
# exists to prevent. It cost one wrong answer while the check was written.
rm -rf _build/test/lib/macula_e2e/test
rebar3 as test compile

erl -noshell -pa _build/test/lib/*/ebin -eval '
  {ok, _} = xref:start(e2e_xref_test),
  ok = xref:set_library_path(e2e_xref_test, code:get_path(), []),
  {ok, _} = xref:add_directory(e2e_xref_test, "_build/test/lib/macula_e2e/test"),
  case xref:analyze(e2e_xref_test, undefined_function_calls) of
      {ok, []} ->
          io:format("xref (test beams): no undefined calls~n"),
          halt(0);
      {ok, Findings} ->
          [io:format("undefined call: ~p~n", [F]) || F <- Findings],
          halt(1);
      {error, Reason} ->
          io:format("xref could not run: ~p~n", [Reason]),
          halt(1)
  end.'
