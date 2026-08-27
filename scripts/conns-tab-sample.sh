#!/usr/bin/env bash
# Quick-sample conns_tab size on every real fleet station.
# Usage: conns-tab-sample.sh [label]
# Prints: <unix_ts> <label> <station>=<conns_tab_size>...

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:-snapshot}"

EVAL='try ets:info(macula_station_peer_observer_conns, size) catch _:_ -> undefined end.'

ts="$(date +%s)"
printf "%s %s" "$ts" "$LABEL"
# Read the whole table into an array first, not `while read < <(...)':
# `ssh' inside that loop reads its own stdin from the same fd the loop
# is consuming, so it silently eats the rest of the table after the
# first iteration.
mapfile -t FLEET_ROWS < <("${HERE}/fleet-table.sh")
for row in "${FLEET_ROWS[@]}"; do
  IFS='|' read -r ssh_host ssh_key cont name <<< "$row"
  size=$(ssh -i ~/.ssh/"$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 \
    root@"$ssh_host" "docker exec $cont /opt/macula_station/bin/macula_station eval '$EVAL'" 2>/dev/null \
    | tr -d ' \n\t\r')
  printf " %s=%s" "$name" "$size"
done
echo
