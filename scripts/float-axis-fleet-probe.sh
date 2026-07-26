#!/usr/bin/env bash
# float-axis-fleet-probe.sh — ask the LIVE station fleet what it does to a
# raw float in a pubsub payload.
#
# Runs the `floats' payload axis (single-station + one real station hop)
# against two live stations. The probe compares the received leaf to the
# published leaf, so the result names what actually arrived instead of
# only reporting whether an event showed up:
#
#   ok                                  float survived byte-exact
#   {payload_mismatch, expected, .., got, ..}
#                                       the wire was alive and the float
#                                       leaf was rewritten — `got' shows
#                                       into what
#   {no_event, ..}                      nothing arrived: routing, not the
#                                       codec (multi-hop propagation is a
#                                       known-open defect)
#
# MACULA VERSION MATTERS AND IS THE POINT.
#
# Pin the probe to the SAME macula the fleet image was built with, or the
# run measures a version mismatch instead of the fleet. Stations on
# :1cc02bc were built against `{macula, "~> 5.1"}'. macula 7.0.0 emits
# IEEE 754 binary64 (CBOR major 7) for floats; a 5.x/6.x station has no
# clause for major 7, and its receive path re-parses a frame it cannot
# decode without advancing the buffer. Do NOT aim a 7.x producer at a
# pre-7 fleet from here.
#
# Usage:
#   ./scripts/float-axis-fleet-probe.sh                 # fleet-matched (~> 5.1)
#   MACULA_PIN='~> 7.0' ./scripts/float-axis-fleet-probe.sh
#
# Env:
#   MACULA_PIN   macula requirement for this run   (default '~> 5.1')
#   PUB_SEED     publisher bootstrap URL
#   SUB_SEED     subscriber bootstrap URL (a DIFFERENT box, for the hop)
#   CASES        comma-separated ct cases. Pass `cross_station_pubsub'
#                as a control whenever the cross-station float case
#                reports `no_event': a plain payload that also fails to
#                cross means the hop is down and the float leg measured
#                nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

MACULA_PIN="${MACULA_PIN:-~> 5.1}"
PUB_SEED="${PUB_SEED:-https://station-be-leuven-arenberg.macula.io:4433}"
SUB_SEED="${SUB_SEED:-https://station-be-leuven-centrum.macula.io:4433}"
CASES="${CASES:-pubsub_axis_floats,cross_station_pubsub_axis_floats}"

restore() {
    git checkout -- rebar.config 2>/dev/null || true
}
trap restore EXIT

echo ">> pinning macula = ${MACULA_PIN} for this run (rebar.config restored on exit)"
perl -0pi -e "s/\{\s*macula\s*,\s*\"[^\"]*\"\s*\}/{macula, \"${MACULA_PIN}\"}/g" rebar.config

# A stale lock pins deps while `rebar3 compile' still reports success —
# that is how services "verified" against dependencies three majors old.
rm -f rebar.lock
rm -rf _build/default/lib/macula _build/test/lib/macula

rebar3 compile >/dev/null
RESOLVED=$(grep -oE '\{vsn,"[^"]*"\}' _build/default/lib/macula/ebin/macula.app \
           | head -1 | sed 's/{vsn,"//;s/"}//')
echo ">> resolved macula = ${RESOLVED}"
echo ">> pub  = ${PUB_SEED}"
echo ">> sub  = ${SUB_SEED}"

MACULA_E2E_BOOTSTRAP="${PUB_SEED}" \
MACULA_E2E_BOOTSTRAP_OTHER="${SUB_SEED}" \
    rebar3 ct --suite=test/macula_e2e_SUITE --case="${CASES}"
