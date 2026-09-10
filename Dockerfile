# macula-e2e — runner image.
#
# Stage 1 builds the rebar3 project (slow: macula ships Rust NIFs that
# compile from source). Stage 2 ships compiled artifacts + test sources +
# erl/rebar3 to invoke `rebar3 ct' at runtime.
#
# Both stages alpine-musl on OTP 28. OTP 27's crypto has no ML-DSA and no
# ML-KEM, and this harness has to follow the fleet onto post-quantum.

# ----- builder ---------------------------------------------------------
FROM erlang:28-alpine AS builder

# Install build deps. Use rustup rather than alpine's `rust' package
# because some macula NIF transitive crates (time-core@0.1.8 etc.)
# require rustc >= 1.88 — alpine's package lags.
RUN apk add --no-cache \
        git build-base pkgconfig openssl-dev curl ca-certificates \
        cmake perl linux-headers
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
# musl-targeted rustup defaults to crt-static, which can't produce
# cdylibs (the macula_quic NIF needs one). Disable it. Mirrors the
# hecate-stub Dockerfile's pattern.
ENV RUSTFLAGS="-C target-feature=-crt-static"

WORKDIR /work
COPY rebar.config ./
COPY src src/
RUN rebar3 deps && rebar3 compile

# ----- runtime ---------------------------------------------------------
FROM erlang:28-alpine

RUN apk add --no-cache libssl3 ca-certificates

WORKDIR /work
COPY --from=builder /work /work
COPY rebar.config ./
COPY test test/
COPY scripts/run-once.sh /usr/local/bin/run-once.sh
RUN chmod +x /usr/local/bin/run-once.sh

# No default MACULA_E2E_BOOTSTRAP. The deployment supplies the seeds (beam00
# derives them from stations.csv), and a run without them fails instead of
# dialing a guessed address.
ENTRYPOINT ["/usr/local/bin/run-once.sh"]
