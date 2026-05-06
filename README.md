# macula-e2e

End-to-end harness against a live Macula relay fleet. Verifies every
public V2 surface in `macula 4.x` (pubsub, RPC, streaming RPC, DHT)
plus the live `_mesh.weather` topic that the stub fleet publishes to.

Designed to evolve into a soft real-time mesh-health dashboard
without rewriting the probe code (see [evolution path](#evolution-path)
below).

---

## What it covers

| Probe | Verifies |
|---|---|
| `pool_health` | Pool has `healthy_links > 0` |
| `pubsub_roundtrip` | Two pools — subscribe + publish + receive |
| `realm_isolation` | Same topic, two realms, no cross-talk + same-realm sanity |
| `unary_rpc` | Advertise + call across two pools |
| `streaming_rpc` | Server-stream advertise + call_stream + chunk drain (the A4 wire on a real station) |
| `dht_put_find` | put_record + find_record round-trip on a fresh-identity node_record |
| `weather_subscribe` | Live `_mesh.weather` ≥ 1 event in 75s under realm `io.macula` |
| `pool_close_cleanup` | `macula_event_gone` delivered on pool close |

Probes live in `src/macula_e2e_probe.erl` as standalone functions
returning `ok | {error, Reason}`. The CT suite in
`test/macula_e2e_SUITE.erl` is a thin wrapper that opens the pools,
calls the probes, and `ct:fail`s on error. Future iterations of this
repo will reuse the probe module for periodic dashboard runs (see
below) without touching the probe logic.

---

## Quick start

### Local

```bash
rebar3 ct --suite test/macula_e2e_SUITE
```

Default bootstrap: `https://boot.macula.io:4433`. Override:

```bash
MACULA_E2E_BOOTSTRAP="https://station-be-kortrijk.macula.io:4433" \
  rebar3 ct --suite test/macula_e2e_SUITE
```

### Container

```bash
docker run --rm --network host \
  -e MACULA_E2E_BOOTSTRAP=https://station-be-kortrijk.macula.io:4433 \
  ghcr.io/macula-internal/macula-e2e:latest
```

`--network host` matters: the suite needs UDP/4433 outbound to reach
QUIC-listening stations. Default Docker bridge networking masquerades
behind the host's egress, which works most of the time but can break
on hosts with strict NAT.

The runner exits non-zero on any test failure. Suite skips cleanly
(exit 0, all SKIPPED) when the bootstrap is unreachable — offline runs
do not crash the schedule.

---

## Configuration

| Env var | Default | Notes |
|---|---|---|
| `MACULA_E2E_BOOTSTRAP` | `https://boot.macula.io:4433` | Comma-separated seed URLs. The pool spawns one peering link per seed. |

Realm tags are derived inside the suite:

- `_test` — synthetic test traffic (pubsub, RPC, streaming, DHT)
- `_test_a` / `_test_b` — realm isolation cross-test
- `io.macula` — weather subscription

All tags are SHA-256 of the realm name (the canonical 32-byte form
the SDK uses).

---

## Evolution path

This repo is staged to grow from a periodic CT runner into a soft
real-time mesh-health dashboard. The factoring of `macula_e2e_probe`
is the lever — every phase reuses it.

### Phase 0 — periodic CT runner (today)

- CT suite runs the probes once and exits.
- Container is built into `ghcr.io/macula-internal/macula-e2e:latest`
  by GH Actions on every push to `main`.
- Scheduled via systemd timer / cron / docker-compose-with-restart on
  one or more lab nodes; per-node deployment lives in
  [`macula-internal/macula-demo/infrastructure/<box>/`](https://codeberg.org/macula-internal/macula-demo).
- Failures surface in journald per container run.

### Phase 1 — long-running probe daemon

- New `src/macula_e2e_dashboard.erl` gen_server.
- Each probe runs on its own cadence (cheap → every 30s, expensive →
  every 5min). Last-result cache keyed by probe name.
- Cowboy endpoint:
  - `GET /api/status` — JSON of `[#{probe, last_run_ts, ok, last_error, p50_latency_ms, ...}]`.
  - `GET /` — minimal HTML status grid (HTMX polling).
- Probe module is unchanged. CT suite still works against the same
  module; the daemon is an additional consumer.

### Phase 2 — multi-vantage mesh-native dashboard

- Probe daemon runs on every beam node (deployed via macula-demo).
- Each daemon publishes results to `_e2e.results` topic on the mesh
  itself, tagged with origin node_id + geographic site.
- A subscriber-side aggregator (could be a slot in the macula-realm
  web UI or a standalone collector) tallies per-vantage results and
  renders a topology grid.
- Multi-vantage detection: the silent fleet failure observed during
  the macula 4.0.0 release work — where every per-box smoke check
  looked clean by transitivity but the actual cross-station traffic
  was zero — would light up red here as `weather_subscribe` failures
  cluster across vantages.
- Bootstrap: an out-of-band fallback (a single station's HTTP
  health endpoint, or a journald scrape) is needed because if the
  mesh is fully dark the probes can't publish their failures —
  the dashboard's silence is itself the signal, but only if you're
  watching liveness.

The same `macula_e2e_probe` module powers all three phases. Rewrite
the runners; never rewrite the probes.

---

## Adding a new probe

1. Add `-spec my_probe(...) -> result().` to `src/macula_e2e_probe.erl`,
   returning `ok | {error, Reason}`.
2. Add a thin wrapper test case in `test/macula_e2e_SUITE.erl`.
3. Add the test name to `all/0`.
4. Done. The Phase 1/2 runners pick it up automatically once they're
   built (they iterate the probe module's exported functions).

Probes should be idempotent and leave no production state behind —
or, when they must (DHT puts, advertise/unadvertise pairs), use
unique-suffixed names + `unadvertise` cleanup so a failed run doesn't
leak entries.

---

## License

Apache-2.0. See [LICENSE](LICENSE).
