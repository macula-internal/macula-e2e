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

# Install build deps. Use rustup rather than alpine's `rust' package
# because some macula NIF transitive crates (time-core@0.1.8 etc.)
# require rustc >= 1.88 — alpine's package lags.
RUN apk add --no-cache \
        git build-base pkgconfig openssl-dev curl ca-certificates
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

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
