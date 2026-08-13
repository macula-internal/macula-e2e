# Reliability, correctness and self-healing — macula / macula-station

**Session opened:** 2026-08-13
**Goal:** two services, each connected to a *different* live station, exercising
every macula application primitive under torture. Then diagnose, then correct.
**Status:** running. Appended to as findings land.

---

## The end goal, in one line

> A service must survive a live mesh: its far station restarts, its link drops,
> its peer refuses, and it keeps working without an operator.

Everything below is measured against that sentence.

---

## What was built

| Thing | What it is |
|---|---|
| `macula_e2e_reach` + `scripts/fleet-reach.sh` | Dial every station, report node id per name, flag two names answering as one station |
| `macula_e2e_service` | One service: a pool pinned to ONE station plus the surface a real service exposes — procedures that succeed, refuse, crash and stall, a server stream, an inbox |
| `macula_e2e_duel` + `scripts/duel.sh` | 23 rounds driving every primitive between two services on two stations, both directions, with the gate that they really are two stations |
| `scripts/station-udp-witness.sh` | Witness whether a client's QUIC packets ARRIVE at a station — splits "the station is broken" from "the path is broken" where ping cannot, since ICMP is filtered fleet-wide |
| `scripts/station-eval.sh` | Read a live station's internal state (admin ports are firewalled from outside the box) |

The duel exists because the existing probes open two pools against **one**
bootstrap and call them "server" and "caller". That is the SDK talking to
itself through one station, and it cannot see anything a relay does wrong.

---

## 1. Fleet reachability — MEASURED

`scripts/fleet-reach.sh` from the Tienen workstation over native IPv6.

| station | reachable | dial ms | node id | FLEET.md |
|---|---|---|---|---|
| station-de-falkenstein | yes | 275 | `da0ebb0323a2f88e` | ✅ |
| station-fi-helsinki | yes | 252 | `30df246a0b71fcb6` | ✅ |
| station-de-nuremberg | yes | 251 | `3504fffe4e2cc057` | ✅ |
| station-fr-paris | yes | 251 | `749af997c4fabf28` | ✅ |
| station-de-frankfurt | yes | 251 | `921afb8c40b23f46` | ✅ |
| **station-it-milan** | **NO** | 20080 (timeout) | — | ❌ |
| station-se-stockholm | yes | 251 | `02c674912d67430f` | ✅ |

Identity collisions: none. Six node ids match FLEET.md byte for byte, so the
inventory is accurate and no name is a repointed retired alias.

---

## 2. `station-it-milan` is dead and reports healthy — SEVERE

The headline self-healing defect of the session, and it was found by the
cheapest probe in the repo.

**What was measured, in order:**

1. Dial times out. Zero healthy links, 20 s.
2. The box is up 128 days. `macula-station-milan` is `Up 30 hours (healthy)`.
   Docker's healthcheck is green. No firewall (`ufw` inactive, `ip6tables`
   policy ACCEPT). The station is listening: `beam.smp` holds
   `[2600:3c0b::2000:1fff:fe35:416b]:4433`.
3. `station-udp-witness.sh` ran `tcpdump` on the box during a dial.
   **The packets arrive.** 28 QUIC Initials and retransmits from this
   workstation, inbound, over 25 seconds.
4. **Nothing goes out.** Not one packet. Not a reply to me, and not a keepalive
   to any peer, in the whole window.
5. The listener process is alive, mailbox 0, bound to the right address, and
   reports `#{connected => 54, handshaking => 0, rejected => 0, cap => 1000}`.
6. `peer_observer` holds 54 conns. Every one has `outbound => undefined`.
   `macula_station_peer_links:connected_hostnames()` is `[]`.

Compare a healthy leaf on the same provider, same shape, same image:

| | milan | stockholm |
|---|---|---|
| conns | 54 | 8 |
| with outbound | **0** | 1 (helsinki, as designed) |
| verified hostnames | **[]** | `["station-fi-helsinki.macula.io"]` |
| packets out in 25 s | **0** | n/a (reachable in 251 ms) |

**The finding:** milan's transport is dead. Its BEAM-side bookkeeping says it
has 54 connected peers, its listener reports a clean cap, its container
healthcheck says healthy, and it has served nothing for 30 hours. It never
dialled its one outbound peer (paris) and it answers no inbound Initial.

Nothing in the station notices, and nothing recovers. Every liveness signal the
station publishes about itself is derived from state that a dead transport does
not disturb. **A station cannot currently detect that its own transport has
stopped moving packets.** That is the gap: the healthcheck asks the application
whether it thinks it is well, and never asks the wire.

The 54 conns are internally consistent with the listener's count, so no counter
disagrees with another — which is precisely why nothing fires. The only two
things that disagree are the station and the network, and no probe compares
those two.

Milan also logs, every 15 minutes since the restart:

```
[dht_replicate] 1/1 held records expire before the next tick (300000ms)
and will lapse between refreshes -- the replicate cadence is above the
publisher TTL
```

That warning is doing its job (it was added after a 288× cadence violation
decayed the fleet silently) but it is a *consequence* here: an isolated station
holds only its own record.

Milan is a degree-1 leaf that FLEET.md already flags as half-joined, so it is
**excluded from the torture pair** — a leaf cannot carry a cross-station
measurement. Recorded as a fleet defect, not a blocker.

### 2.1 The reboot confirmed the diagnosis

Raf rebooted the box. Before and after, via `scripts/station-joined.sh`:

| | before | after reboot |
|---|---|---|
| reachable from outside | **no** (20 s timeout) | **yes**, 251 ms |
| conns | 54 | 7 |
| **with outbound** | **0** | **1** (paris, as designed) |
| **verified hostnames** | **[]** | **1** |
| listener connected | 54 | 6 |

The whole fleet is now green, and milan answers with node id `af7b6b1ad72b1120`
— matching FLEET.md, so the identity survived and the data volume is intact.

This is the diagnosis confirmed rather than merely consistent: the transport was
wedged, the 54 conns were phantom, and a restart clears it. The station itself
never noticed and never would have. **The defect is not that milan broke — it is
that nothing but a human dialling it from outside could tell.**

`scripts/station-joined.sh` now encodes the signature so the next one is caught
by a script instead of a session: conns held with zero outbound, or an empty
verified-peer set, while the station reports healthy.

### 2.2 Still half-joined — the leaf defect is separate and survives

Reachability came back; the record layer did not.

| | records held | routing entries |
|---|---|---|
| station-it-milan (6 min after restart) | **1** (its own) | **1** (itself) |
| station-se-stockholm (up 2 weeks) | 16 | 4 |

Milan holds seven connections and one verified peer, and still knows only
itself. That is FLEET.md's documented "leaves are only HALF joined" defect, and
it is **not** what the reboot fixed — it is a second, independent problem that a
restart does not touch. Being reachable and being joined are different states,
which is exactly why `station-joined.sh` checks both.

Re-checked after two replicate ticks; see §2.3.

---

## 3. Stale topology in the harness — CORRECTED

`macula_e2e_fleet:default_stations/0` carried the **retired Leuven topology**:
nine stations across three boxes, decommissioned 2026-07-27. The same nine-entry
list was independently copy-pasted into `scripts/torture-mesh.sh` and
`scripts/torture-mesh-concurrent.sh`. Three copies, all stale.

Worse than a dead list: retired station DNS was **repointed** at the surviving
station on its box rather than deleted. A stale name still resolves, still
completes a QUIC handshake, still reports healthy — and every per-station claim
built on it is fabricated, with nothing to say so.

**Corrected.** `macula_e2e_fleet` now carries the as-deployed seven-station
topology and is the single source of truth, exposing what callers need instead
of making them rebuild it: `names/0`, `domain/0`, `port/0`, `seed_url/1`,
`core/0`, `leaves/0`, `two_hop_pair/0`.

`two_hop_pair/0` is the load-bearing one. The core five are a full mesh **minus
the helsinki↔nuremberg edge**, so that pair is the fleet's only genuine
multi-hop path. A cross-station probe wired to any other core pair measures one
hop while the data reads as two.

`macula_e2e_reach` is the check that would have caught the stale list: it
reports the node id per name and flags two names answering as one station.

---

## 4. Version skew — MEASURED, and it costs a real feature

macula is **8.0.0** on hex and in its local tree. Of ~45 consumers in the
workspace, **two** resolve it (`hecate-tom-player`, `hecate-mpong-bot`).

| participant | pins | on 8.0.0 |
|---|---|---|
| `macula-station` (the live fleet) | `~> 7.1` | no |
| `macula-realm`, `macula-dist-relay` | `~> 7.0` | no |
| `macula-e2e` | was `~> 7.0` → **now `~> 8.0`** | yes |
| `macula-torture` | `~> 7.0` | no |
| 22 `hecate-*` services | transitively via `hecate_om` | no |

**Nothing actually breaks on 8.0.0** in macula-station, macula-e2e or
macula-torture. All five `call/5` sites match `{ok,_}` / `{error,_}` generically
or discard the return; there is no `{call_error, ...}` pattern match and no
`unknown_error` literal in any of the three. The pins block 8.x for no
functional reason.

**The real blocker is `hecate_om`.** The published `hecate_om 0.9.0` on hex pins
`{macula, "~> 7.0"}`, and 22 hecate services take macula only through it. One
line in one published package holds the whole services tier on 7.x. The local
`hecate_om` tree already says `~> 8.0`; it has not been published.

### What the skew costs — proven on the live fleet

The duel's `rpc_refusal_reason_survives_hop` round calls a handler that answers
`{error, <<"hold_full">>}`, across two stations with no direct edge:

| harness SDK | result |
|---|---|
| macula 7.0.0 | **FAIL** — `{reason_lost_in_transit, got, {call_error,15,unknown_error}, expected, <<"hold_full">>}` |
| macula 8.0.0 | **ok** — the handler's own reason arrives intact |

This is not a changelog claim, it is a measurement over a real two-hop path.
On 7.x every refusal in the world arrives as the same three words. Every
`hecate-*` service is on 7.x today, so no hecate service can currently tell a
caller *why* it said no.

**Also worth flagging, unrelated to pins:** `hecate-warden` and
`hecate-sentinel` `_build` trees still carry macula **5.1.0**, two majors behind
the 7.x wire the fleet speaks. Both are live fleet participants.

---

## 5. Duel results — 23 rounds, two services, two stations

Run over `station-fi-helsinki` ↔ `station-de-nuremberg` (the two-hop pair), four
runs. `distinct_stations` passed every time, so every result below is a genuine
cross-station measurement.

**Green and stable across all runs:** pool health, pubsub a→b,
unsubscribe-stops-delivery, no-duplicates, RPC echo both directions, handler
crash reported, service survives handler crash, unknown procedure refused,
unadvertise stops serving, stream order + EOF, DHT put/find cross-station,
absent key not found, content round trip, 24 concurrent calls, 120-event
sustained pubsub.

That green list is worth stating plainly: **teardown works, refusal works,
crash isolation works, streams keep their order, and the mesh carries sustained
concurrent load across two hops.** The failures below sit inside a system that
is mostly correct.

### 5.1 Pubsub does not preserve publish order — 4/4 runs

25 events published in order, delivered with **68 inverted pairs out of 300**.
Not a swap or two: delivery order is largely unrelated to publish order.

⚠ **macula specifies nothing about pubsub ordering** — not that it holds, not
that it does not. Nothing in the SDK source, its guides, its CHANGELOG or the
station's routing code mentions per-topic order. So this is not a broken
promise; it is an unwritten one that a consumer will assume by default. Any
telemetry, game-state or projection consumer that assumes order is wrong today
and has no way to know.

This is the first time it has been measured. Every existing drain folds payloads
into a `sets:set`, which discards order by construction, so all of them pass
against a mesh that reorders freely.

**Owed:** a decision, then a sentence in the docs. Either pubsub is ordered
per (realm, topic, publisher) and this is a defect, or it is not and every
consumer needs to know.

### 5.2 Re-advertise can permanently lose the route — 2/4 runs, SEVERE

`unadvertise` then `advertise` of the same procedure, and the far station never
routes to it again:

```
rpc_readvertise_restores_serving
  {readvertise_never_restored_route,
     first, {call_error,1,unknown_next_peer},
     retry, {call_error,1,unknown_next_peer}}
```

The retry is 12 seconds after the first attempt — well past the registry's 10 s
tombstone TTL. When it fails it does not recover, and every later round using
that procedure fails with it (that is what took down `rpc_deadline_is_enforced`
and all 24 `torture_concurrent_calls` in the same run).

This is exactly the shape a service hits on restart: re-advertise what it
advertised a moment ago, and be unreachable afterwards with nothing in its own
logs to say so.

`macula_remote_advertise_registry` looks correct on inspection — its tombstone
carve-out explicitly allows a same-source re-advertise through
(`OrigAdv =:= NewAdv -> allow`), and its moduledoc names this exact race:
"the partial-mesh gossip-vs-unadvertise race never converges if any register
call after unregister can resurrect the entry."

**The one-hop control run (§5.5) clears the registry entirely: this round passes
on a directly connected pair.** The defect is in the cross-station propagation
of the re-ADVERTISE over the two-hop path, not in the registry that receives it.

### 5.3 Content above the chunk boundary is late, not lost — 3/4 runs

`put_content/2` answers `ok`, and the blob is then **not readable from the
other station** until seconds later.

| size | result |
|---|---|
| 1 KiB, 64 KiB, 256 KiB, 256 KiB + 1 | ok, first attempt |
| 1 MiB | `{content_arrived_late, 1048576, attempts, 2}` — arrives on retry ~3 s later |

Every content probe in this repo is hardcoded at 8192 bytes, so the boundary had
never been approached. `put_content` returning `ok` means the *writer's* station
stored it, and nothing tells the caller when it becomes fetchable elsewhere.
A read-after-write from a second station is a race with no documented bound.

Retrying is what separates "late" from "lost" — a single `get` cannot, and the
first run of this round reported a hard failure at 256 KiB that a retry would
have shown to be lag.

### 5.4 Single-publish delivery is intermittent — 2/4 runs

`pubsub_b_to_a` — one subscribe, settle, one publish, 8 s wait — returned
`{no_event, ...}` in two of four runs, while the a→b direction passed every
time. Same code, opposite direction. The fleet's dial graph is directed and
relay routing tables are per-direction, which is why the round runs both ways;
no existing cross-station probe does.

Sustained pubsub (120 events) passed every run, so this is not gross breakage —
it is a first-event or route-warmup loss that a rate hides.

### 5.5 The one-hop control run — three of four failures are MULTI-HOP ONLY

The same 23 rounds against `station-fr-paris` ↔ `station-de-falkenstein`, a pair
with a **direct edge in both directions**. One variable changed: hop count.

| round | 2 hops (helsinki↔nuremberg) | 1 hop (paris↔falkenstein) |
|---|---|---|
| `rpc_readvertise_restores_serving` | **FAIL** 2/4 | **ok** |
| `pubsub_b_to_a` | **FAIL** 2/4 | **ok** |
| `content_size_axis` (1 MiB) | **FAIL** 3/4 (late) | **ok**, first attempt |
| `pubsub_ordering` | FAIL, 68 inversions | **FAIL, 121 inversions** |
| all other rounds | ok | ok |

**22/23 on one hop. 17/23 on two.**

This is the most useful result of the session, because it splits the findings
cleanly in two:

- **Route loss, first-event loss and content lateness are multi-hop defects.**
  They do not occur across a direct edge. Whatever carries advertises, first
  publishes and content blocks between two stations that are not directly
  connected is where all three live. That is one place to look, not three.
- **Ordering is not a hop problem at all.** It fails on a single hop, and
  *worse* — 121 inverted pairs of 300 versus 68 over two hops. So the reordering
  is inherent to the fan-out, not to relaying, and the extra hop's latency if
  anything smooths it. Any "fix the multi-hop path" work will not touch it.

Worth stating for the fleet: the FLEET.md note that helsinki↔nuremberg is the
only genuine multi-hop path among the core five is doing real work here. Wire
this harness to any other core pair and six of these results turn green while
nothing has been fixed.

---

## 6. Station-hosted handlers refuse through the wrong frame — static finding

Read directly, not measured: `macula_handler_dispatch:safe_invoke/4` sends a
handler's `{error, Reason}` back inside a **RESULT** frame
(`normalise({error,_} = Error) -> Error`, then `result_frame/3`). A caller
therefore sees `{ok, {error, Reason}}`, not `{error, Reason}`.

An SDK-hosted handler returning the same tuple reaches the caller as
`{error, Reason}`. **Same handler source, different caller contract depending on
where it is hosted.** A caller matching `{ok, _}` as success treats a refusal as
a success.

Separately, `error_frame/3` never sets `detail`, so even the crash and
not-found paths give an 8.0.0 caller nothing to read — 8.0.0's whole point is
that `detail` is where the reason lives.

The duel's refusal round covers the SDK-hosted path (that is what a service
uses). `classify_refusal/2` names the station-hosted shape explicitly rather
than passing it, so if a station-hosted handler is ever put under this round it
reports `refusal_arrived_as_success_frame` instead of a silent green.

---

## 7. Corrections to my own work

`dht_find_records_by_type` failed three runs before I checked what macula
promises. `find_records_by_type/2` is documented as a **per-station view** —
"each station sees its local replicas plus whatever its peers have gossiped" —
so a record absent from the *far* station's listing is correct behaviour. The
round was asserting a mesh-wide listing that macula never offered, and was
manufacturing a red.

Corrected to assert the invariant that is real (a station must list a record it
just accepted) and to report the far station's listing as information. It now
passes.

Recorded because the same mistake is what makes a harness untrustworthy: a red
that is the test's fault costs more than no test.

---

## 8. Defects found by reading, not yet measured

From the SDK audit, ranked by what a live service would feel. All are in
`macula_client` — the pool every service holds for days.

1. **`status/1`, `links/1` and `publish/4` can crash the whole pool.** Each
   calls `macula_station_link:is_connected/1` — a `gen_server:call` — with no
   protection, from inside the pool's own gen_server. A link dying between the
   `is_process_alive/1` check and the call exits `{noproc,_}` **inside the
   pool**, killing every subscription, advertisement and pending call. The
   window is exactly when links are flapping.
2. **`status/1` can time out its own caller.** It probes every link
   sequentially, each capped at 1 s, inside a handler the caller waits 5 s for.
   Five or more hung seeds and the caller exits `{timeout, ...}` — while every
   other pool operation queues behind it.
3. **`publish` with `replication_factor => 0` returns `ok` having sent
   nothing.** `summarize_publish([], NotEmpty) -> ok`.
4. **A restarted pool comes back empty.** Under `child_spec/3` the supervisor
   restarts the pool, but subscriptions, advertisements and stream
   advertisements all lived in the dead pool's state. Application-held
   `SubRef`s are silently stale.

---

## 9. What is corrected, and what is owed

**Corrected this session**

- `macula_e2e_fleet` — live seven-station topology, single source of truth,
  with the two-hop pair named
- `macula_e2e_reach` + `fleet-reach.sh` — reachability and identity-collision check
- `macula-e2e` bumped `~> 7.0` → `~> 8.0`, verified green on the live fleet
- `macula_e2e_service` + `macula_e2e_duel` — the two-service torture, 23 rounds
- `station-udp-witness.sh`, `station-eval.sh` — the two instruments the milan
  diagnosis needed and the repo did not have
- `dht_find_records_by_type` round corrected to macula's actual contract

**Owed, ranked**

1. Restart `macula-station-milan`, then give the station a liveness check that
   asks the **wire**, not the application — a station that has sent zero packets
   while holding N connections is dead and must say so
2. Fix the multi-hop propagation path. §5.5 localises three separate failures
   (re-advertise route loss, first-publish loss, content lateness) to whatever
   carries state between two stations with no direct edge. One place, three
   symptoms
3. Decide and document pubsub ordering — and note it is **not** fixed by the
   above, it fails worse on one hop than two
4. Publish `hecate_om` with `{macula, "~> 8.0"}` — one line unblocks 22 services
5. Bump `macula-station` (`~> 7.1` → `~> 8.0`) and `macula-torture`; nothing
   breaks, both were verified against their call sites
6. `macula_handler_dispatch` — refuse through an ERROR frame with `detail` set,
   so hosted and SDK handlers share one contract
7. Guard the three unprotected `is_connected/1` call sites in `macula_client`
8. Rewire `torture-mesh.sh` and `torture-mesh-concurrent.sh` to read
   `macula_e2e_fleet` instead of their own stale copies
9. `macula_e2e_fault.erl` is complete, careful, docker-level fault injection
   (pause/unpause/stop/start) that **nothing calls**. Link loss and replay have
   zero coverage, and the fleet auto-rolls on every CI build of main — link loss
   is a daily event, not an edge case. The gap between "we can make a station
   disappear" and "we assert what happens when it does" is one round wide.

---

*Appended as work lands.*
