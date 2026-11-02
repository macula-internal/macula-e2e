# macula-e2e

End-to-end harness against a live Macula relay fleet. Verifies every
public V2 surface in `macula 4.x` (pubsub, RPC, streaming RPC, DHT).

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
| `pool_close_cleanup` | `macula_event_gone` delivered on pool close |
| `subscriber_wrapper` | `macula_subscriber` (supervised, macula 9.2.0) — subscribe + publish + receive |
| `rpc_wrapper` | `macula_response` / `macula_request` (supervised, macula 9.2.0) — advertise + call |
| `streaming_wrapper` | `macula_streamer` / `macula_stream_sink` (supervised, macula 9.2.0) — advertise_stream + send + chunk + close |
| `content_wrapper` | `macula_feeder` / `macula_download` (supervised, macula 9.2.0) — put + get round-trip |

The four `*_wrapper` probes exercise the same wire operations as
`pubsub_roundtrip` / `unary_rpc` / `streaming_rpc` / `put_get_content`
above, but driven through the supervised OTP-behaviour wrappers macula
9.2.0 added on top of the raw `macula:*` calls, using
`macula_e2e_wrapper_callback` as their shared behaviour callback
module. They're client-side supervision veneers with no wire-format or
routing change, so single-station coverage is enough — cross-station
routing is already proven by the raw-primitive probes.

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
MACULA_E2E_BOOTSTRAP="https://station-fi-helsinki.macula.io:4433#<64 hex node id>" \
  rebar3 ct --suite test/macula_e2e_SUITE
```

`MACULA_E2E_BOOTSTRAP` is required; there is no default seed. macula 16
refuses a seed that does not name the node id it expects
(`{error, {seeds, expected_node_id_required}}`), and a URL binary cannot carry
one, so a seed is `https://host:port#<node id>` — the ids are published by
mcl-stations' `list_stations`.

### What CI runs, and what it cannot

CI runs `rebar3 as lint lint`, `rebar3 eunit` and `rebar3 xref`, all on
hosted runners. It does not run the suite: the stations are AAAA-only, a
hosted runner has no IPv6 egress, and this repository is public, so no
self-hosted runner may take work from it either.

`xref` is the check that catches what eunit cannot — a call to a module or
function that no longer exists compiles and passes eunit, which is how
sixteen calls to `macula_identity` survived a year of green builds
(macula-internal/macula-e2e#1). It gates: `rebar3 xref` exits 1 on any
finding, so the tree has to stay clean. It checks undefined calls only;
`rebar.config`'s `xref_checks` entry says why `exports_not_used` is not one
of them here.

`rebar3 xref` reads the default profile and never sees `test/`, so the same
job also runs [`scripts/xref-test-beams.sh`](scripts/xref-test-beams.sh): it
compiles the test profile and analyses those beams, which is where a suite's
call to a removed arity would otherwise hide. `seam/` is not covered — its
dependencies are private, so every call there would read as undefined; it
runs by hand where that source is readable.

The live burst runs by hand, from a machine with IPv6 egress, with
[`scripts/run-page-burst.sh`](scripts/run-page-burst.sh): before a portal
release, after any station release or fleet move, and whenever someone
reports a thumbnail that does not render. Green there means the channel
page's eight thumbnails all answer inside the portal's own 5 s deadline.

### Seam suite (station and realm, no fleet)

`seam/realm_seam_SUITE` spawns real stations and a real realm on local
`peer` nodes. It needs the macula-station apps, which come from a private
repository, so they live only in the `seam` profile. The default profile,
lint and the published image never fetch them.

```bash
MACULA_REALM_BUILD=/path/to/macula-realm/_build/test/lib \
  rebar3 as seam ct --suite seam/realm_seam_SUITE
```

It needs read access to macula-station, OTP 28 first on `PATH` (the realm
does not run on OTP 29, and the suite refuses to start there), and a
macula-realm tree built with `mix test` under the realm's own
`.tool-versions`. `ELIXIR_LIB` defaults to that Elixir's `lib`.

### Container

```bash
docker run --rm --network host \
  -e MACULA_E2E_BOOTSTRAP=https://station-fi-helsinki.macula.io:4433 \
  ghcr.io/macula-internal/macula-e2e:latest
```

`--network host` matters: the suite needs UDP/4433 outbound to reach
QUIC-listening stations. Default Docker bridge networking masquerades
behind the host's egress, which works most of the time but can break
on hosts with strict NAT.

The runner exits non-zero on any test failure. The suite fails, never
skips, when `MACULA_E2E_BOOTSTRAP` is unset or no seed yields a healthy
link: a skip exits 0, and an unreachable or refusing fleet must not read
as a green run.

---

## Configuration

| Env var | Default | Notes |
|---|---|---|
| `MACULA_E2E_BOOTSTRAP_OTHER` | none | Seed URL for a second pool on a different station. Without it every `cross_station_*` case skips. The daily beam00 run sets one station from `stations.csv` outside the seed set. |
| `MACULA_E2E_BOOTSTRAP` | none, required | Comma-separated seed URLs. The pool spawns one peering link per seed. The daily beam00 run uses every `regional` station in macula-demo's `topologies/eu/stations.csv`. |

Realm tags are derived inside the suite:

- `_test` — synthetic test traffic (pubsub, RPC, streaming, DHT)
- `_test_a` / `_test_b` — realm isolation cross-test
- `io.macula`: the production realm, used by the mpong-shape probes

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
  [`macula-internal/macula-demo/infrastructure/<box>/`](https://github.com/macula-io/macula-demo).
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
  was zero — would light up red here as `cross_station_pubsub` failures
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
