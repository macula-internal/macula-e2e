#!/usr/bin/env bash
# Print the macula version compiled into a macula-e2e image, without running it
# (containers cannot fork on this workstation, so the file is copied out).
# Usage: check-e2e-image-macula-vsn.sh <tag>
set -u

TAG="${1:?image tag}"
IMG="ghcr.io/macula-internal/macula-e2e:${TAG}"
OUT="$(mktemp -d "$(dirname "$(readlink -f "$0")")/e2e-image-XXXX")"

docker pull -q "${IMG}" || exit 1
docker image inspect "${IMG}" --format 'id={{.Id}} digest={{index .RepoDigests 0}} created={{.Created}}'
cid="$(docker create "${IMG}")" || exit 1
docker cp "${cid}:/work/_build/default/lib/macula/ebin/macula.app" "${OUT}/macula.app"
docker rm "${cid}" > /dev/null
echo "macula in image: $(/usr/bin/grep -o -E '\{vsn,"[^"]+"\}' "${OUT}/macula.app")"
