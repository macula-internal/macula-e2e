#!/bin/sh
# V2 check without starting a process in the container: create a stopped
# container, copy files out, inspect them on the host.
#
# Prints ONE line per image:
#   IMAGE | os=<debian x / alpine x> | libssl=<pkg version> | crypto=<path or none> | ml_dsa=<n> ml_kem=<n>
# ml_dsa/ml_kem count algorithm-name strings in OTP's crypto.so, which only
# appear when OTP was built with them (verified against local OTP 27, 28, 29).
#
# Usage: v2-image-files-check.sh IMAGE
set -u

IMAGE="$1"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/v2-files.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
    echo "$IMAGE | pull failed"
    exit 0
fi
CID=$(docker create "$IMAGE" 2>/dev/null) || { echo "$IMAGE | create failed"; exit 0; }

OS="unknown"
if docker cp "$CID:/etc/alpine-release" "$WORK/alpine" 2>/dev/null; then
    OS="alpine $(cat "$WORK/alpine")"
    docker cp "$CID:/lib/apk/db/installed" "$WORK/apk" 2>/dev/null
    SSL=$(awk '/^P:libssl3$/{p=1} p&&/^V:/{print $0; p=0}' "$WORK/apk" 2>/dev/null | sed 's/^V://' | head -1)
elif docker cp "$CID:/etc/debian_version" "$WORK/debian" 2>/dev/null; then
    OS="debian $(cat "$WORK/debian")"
    docker cp "$CID:/var/lib/dpkg/status" "$WORK/dpkg" 2>/dev/null
    SSL=$(awk '/^Package: libssl3(t64)?$/{p=1} p&&/^Version:/{print $2; p=0}' "$WORK/dpkg" 2>/dev/null | head -1)
else
    SSL=""
fi

CRYPTO_PATH=$(docker export "$CID" 2>/dev/null | tar -t 2>/dev/null | grep -E 'crypto-[0-9.]+/priv/lib/crypto\.so$' | head -1)
if [ -n "$CRYPTO_PATH" ] && docker cp "$CID:/$CRYPTO_PATH" "$WORK/crypto.so" 2>/dev/null; then
    DSA=$(strings "$WORK/crypto.so" | grep -c -i -E 'ml-dsa|mldsa')
    KEM=$(strings "$WORK/crypto.so" | grep -c -i -E 'ml-kem|mlkem')
    CRYPTO="$CRYPTO_PATH | ml_dsa=$DSA ml_kem=$KEM"
else
    CRYPTO="none (no OTP crypto.so)"
fi

docker rm "$CID" >/dev/null 2>&1
echo "$IMAGE | os=$OS | libssl=${SSL:-none} | crypto=$CRYPTO"
