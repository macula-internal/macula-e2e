# macula-e2e — runner image.
#
# Stage 1 builds the rebar3 project (slow: macula 4.x ships Rust NIFs
# that compile from source). Stage 2 ships only the compiled artifacts
# plus the test sources + rebar3 to invoke them at runtime.
#
# Both stages run on Debian bookworm — macula's NIFs were developed
# against glibc and we keep the build/runtime libc consistent.

# ----- builder ---------------------------------------------------------
FROM hexpm/erlang:27.3.4.4-debian-bookworm-20250520 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git build-essential pkg-config libssl-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Rust toolchain — macula's NIFs use cargo + rustler.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /work
COPY rebar.config ./
COPY src src/
RUN rebar3 deps && rebar3 compile

# ----- runtime ---------------------------------------------------------
FROM hexpm/erlang:27.3.4.4-debian-bookworm-20250520

RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY --from=builder /work /work
COPY rebar.config ./
COPY test test/
COPY scripts/run-once.sh /usr/local/bin/run-once.sh
RUN chmod +x /usr/local/bin/run-once.sh

ENV MACULA_E2E_BOOTSTRAP="https://boot.macula.io:4433"
ENTRYPOINT ["/usr/local/bin/run-once.sh"]
