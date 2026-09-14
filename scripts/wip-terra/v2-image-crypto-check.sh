#!/bin/sh
# V2 check: which OpenSSL and which post-quantum algorithms OTP crypto sees
# inside an image. Every container runs with --network none and reads only.
#
# Usage: v2-image-crypto-check.sh IMAGE [ERL_PATH]
#   ERL_PATH defaults to "erl" on PATH (builder images). For a relx release
#   image pass the release root, and the script finds erts-*/bin/erl there.
set -u

IMAGE="$1"
ERL_ROOT="${2:-}"

ERL_EXPR='S = crypto:supports(),
F = fun(A) when is_atom(A) -> L = atom_to_list(A), lists:prefix("ml", L) orelse lists:prefix("slh", L); (_) -> false end,
PQ = [{K, [A || A <- V, F(A)]} || {K, V} <- S, is_list(V)],
io:format("otp=~s~ninfo_lib=~p~npq=~p~n", [erlang:system_info(otp_release), crypto:info_lib(), PQ]),
halt().'

INNER='
echo "debian=$(cat /etc/debian_version 2>/dev/null || echo none)"
echo "openssl_cli=$(openssl version 2>/dev/null || echo absent)"
dpkg-query -W -f="\${Package} \${Version}\n" "libssl*" 2>/dev/null || true
ERL=erl
if [ -n "$ERL_ROOT" ]; then ERL=$(ls "$ERL_ROOT"/erts-*/bin/erl | head -n 1); fi
CRYPTO_SO=$(find / -name "crypto.so" -path "*crypto-*" 2>/dev/null | head -n 1)
echo "crypto_so=$CRYPTO_SO"
ldd "$CRYPTO_SO" 2>/dev/null | grep -E "libcrypto|libssl" || echo "crypto.so: no dynamic libcrypto"
"$ERL" -noshell -eval "$ERL_EXPR"
'

echo "##### $IMAGE"
docker pull -q "$IMAGE" >/dev/null
PULL_RC=$?
echo "pull_rc=$PULL_RC"
docker run --rm --network none --user 0 --entrypoint sh \
    -e ERL_EXPR="$ERL_EXPR" -e ERL_ROOT="$ERL_ROOT" \
    "$IMAGE" -c "$INNER"
echo "run_rc=$?"
