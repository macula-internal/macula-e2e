# macula-e2e — runner image.
#
# Stage 1 builds the rebar3 project (slow: macula 4.x ships Rust NIFs
# that compile from source). Stage 2 ships compiled artifacts + test
# sources + erl/rebar3 to invoke `rebar3 ct' at runtime.
#
# Both stages alpine-musl. Matches the workspace convention
# (hecate-stub, hecate-daemon, macula, reckon-* all build against
# erlang:27-alpine).

# ----- builder ---------------------------------------------------------
FROM erlang:27-alpine AS builder

RUN apk add --no-cache \
        git build-base pkgconfig openssl-dev rust cargo curl ca-certificates

WORKDIR /work
COPY rebar.config ./
COPY src src/
RUN rebar3 deps && rebar3 compile

# ----- runtime ---------------------------------------------------------
FROM erlang:27-alpine

RUN apk add --no-cache libssl3 ca-certificates

WORKDIR /work
COPY --from=builder /work /work
COPY rebar.config ./
COPY test test/
COPY scripts/run-once.sh /usr/local/bin/run-once.sh
RUN chmod +x /usr/local/bin/run-once.sh

ENV MACULA_E2E_BOOTSTRAP="https://boot.macula.io:4433"
ENTRYPOINT ["/usr/local/bin/run-once.sh"]
