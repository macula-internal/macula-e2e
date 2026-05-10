#!/usr/bin/env bash
# Quick-sample conns_tab size on every station in the Leuven mesh.
# Usage: conns_tab_sample.sh [label]
# Prints: <unix_ts> <label> <station>=<conns_tab_size>...

set -u
LABEL="${1:-snapshot}"
STATIONS=(
  "stations-hetzner-falkenstein.macula.io|macula-station-brussels|centrum"
  "stations-hetzner-falkenstein.macula.io|macula-station-ghent|gasthuisberg"
  "stations-hetzner-falkenstein.macula.io|macula-station-bertem|bertem"
  "relays-hetzner-helsinki.macula.io|macula-station-antwerp|haasrode"
  "relays-hetzner-helsinki.macula.io|macula-station-leuven|kessel-lo"
  "relays-hetzner-helsinki.macula.io|macula-station-linden|linden"
  "relays-hetzner-nuremberg.macula.io|macula-station-bruges|bruges"
  "relays-hetzner-nuremberg.macula.io|macula-station-hasselt|hasselt"
  "relays-hetzner-nuremberg.macula.io|macula-station-wijgmaal|wijgmaal"
)

EVAL='try ets:info(macula_station_peer_observer_conns, size) catch _:_ -> undefined end.'

ts="$(date +%s)"
printf "%s %s" "$ts" "$LABEL"
for spec in "${STATIONS[@]}"; do
  host="${spec%%|*}"
  rest="${spec#*|}"
  cont="${rest%%|*}"
  name="${rest#*|}"
  size=$(ssh -i ~/.ssh/id_hetzner -o BatchMode=yes -o ConnectTimeout=10 \
    root@"$host" "docker exec $cont /opt/macula_station/bin/macula_station eval '$EVAL'" 2>/dev/null \
    | tr -d ' \n\t\r')
  printf " %s=%s" "$name" "$size"
done
echo
