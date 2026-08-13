# Macula: architecture and fleet, assessed 2026-08-13

**Basis:** one session of live measurement against the seven-station fleet, plus
source audit of `macula` 8.0.0, `macula-station`, `macula-realm`. Everything
below is marked **MEASURED**, **INFERRED** or **UNKNOWN**. Nothing is asserted
from documentation alone, because three separate documents were found stale
during this session and one of them was stale in a way that told operators to
discard good data.

---

## 1. The headline

**The mesh works. It cannot see itself.**

**17 to 21 of 23** application primitives pass across two stations with no direct
edge between them, over four runs. 21/23 is the best run, 17/23 the worst; the
spread is itself a finding, not noise to average away.

Stable in every run: unsubscribe stops delivery, duplicate-freedom, unary RPC
both directions, handler refusal with the reason intact, handler crash
isolation, service survival after a crash, unadvertise stops serving,
server-streaming with ordered chunks, DHT put/find and type listing, absent-key
handling, content round-trip at 8 KiB, 120-event sustained publish.

⚠ **Intermittent across two hops, stable across one:** first single publish
(failed 2 of 4), re-advertise restoring a route (2 of 4, and PERMANENT when it
fails), and the deadline and 24-concurrent-caller rounds, which went down as
collateral in the runs where re-advertise failed. Those four are in the pass
list only in the good runs.

That is a working distributed system, and the failures below should be read
against it rather than instead of it.

What the same session established is that **almost every signal this system
publishes about itself is derived from BEAM state, and BEAM state is undisturbed
by a dead transport.** That is not a bug; it is the shape of the whole
observability surface, and it is why a station served nothing for thirty hours
while every indicator read green.

---

## 2. Fleet — MEASURED

| station | reachable | dial ms | records | routing | swim | conns |
|---|---|---|---|---|---|---|
| falkenstein | yes | 269 | 17 | 4 | — | 7,734 |
| helsinki | yes | 251 | 17 | 4 | 4 | 7,769 |
| nuremberg | yes | 251 | 17 | 3 | — | 2,526 |
| paris | yes | 251 | 17 | 5 | — | 2,538 |
| frankfurt | yes | 251 | 17 | 4 | — | **12,392** |
| milan (leaf) | yes* | 251 | 17 | 5 | **1** | 44 |
| stockholm (leaf) | yes | 251 | 17 | 4 | **1** | 10 |

\* after a reboot. It was unreachable for 30 hours before it.

Dial graph re-verified as-built: 15 directed edges, helsinki↔nuremberg absent in
both directions, unchanged since 2026-07-27. Node ids match FLEET.md byte for
byte on all seven, so identities survived every redeploy.

### 2.1 What is healthy

Reachability, identity stability, the record layer, and the dial topology. All
seven stations hold the same 17 records. The fleet auto-rolls on every push to
main and did so cleanly during this session: watchtower rolled all seven onto a
new build within minutes, and the new code was verified running on real
hardware.

### 2.2 What is not

**SWIM membership is broken on both leaves.** `swim_members = 1` against the
core's 4, indefinitely, exactly as recorded on 2026-07-27. The DHT half of that
defect has since fixed itself; the SWIM half has not. **MEASURED.**

**Inbound peering workers are in the thousands and unequal.** Frankfurt holds
12,392, every worker pid alive, against stockholm's 10. The listener's
`cap => 1000` does not bound this — since macula 4.1.0 the cap counts only
*handshaking* workers, and `in_flight` reads 12,391 against it by design.
**MEASURED. Cause UNKNOWN.** Whether this is a real client population or
accumulation has not been established, and it is the single largest unexplained
number on the fleet.

**One station in seven was dead before a human noticed.** Death at time of
measurement is **MEASURED** (tcpdump: packets in, none out). The **thirty-hour
extent is INFERRED** from container uptime plus the absence of any outbound
state, not observed throughout. Detection has since shipped; see §4.

---

## 3. Architecture — the four structural findings

### 3.1 The wire is not observable from the BEAM — MEASURED

Every send-side quantity in this stack is a statement of intent, not of
transmission:

| signal | what it actually means |
|---|---|
| `macula_peering:send_frame/2` returns `ok` | a `gen_statem:cast` was accepted, possibly by a dead pid |
| router's `forwarded` counter | that cast happened. **INFERRED** that it climbed through the outage — it follows from cast semantics and 54 conns still fanning EVENTs, but the counter was never read on milan and the reboot destroyed the chance |
| `macula_quic:getstat/2` | hardcoded zeros, and its doc called that "harmless… for liveness signals" |
| `macula:publish/4` returns `ok` | one link's peering process accepted a cast. No ack exists anywhere in the protocol |
| `macula:subscribe/4` returns `{ok, Ref}` | nothing. Stations do not acknowledge subscriptions |

The only station-attributable observable that is not BEAM state is the kernel's
own receive queue, read from procfs. That is now the basis of the shipped
tripwire, and it is a **proxy**: it sees ingress stalling, not egress dying. The
outbound client endpoints are process-global Rust statics bound to `[::]:0` with
no Erlang handle at all, so the keepalive that stopped on milan is invisible to
every rung of the fix.

**This is the deepest issue in the system.** Not because a station died, but
because the honest answer to "did that packet leave" is currently *nobody can
tell you*.

### 3.2 Multi-hop is materially weaker than one hop — MEASURED, confound excluded

⚠ **Strengthened after adversarial review.** The first version of this section
said "one variable changed: hop count" against a single control run. That was
wrong: paris↔falkenstein and helsinki↔nuremberg differ in stations, provider and
geography as well as hop count, and one clean run against 2-of-4 intermittent
failures proves little. Two more controls were run to separate station identity
from hop count — each a **direct edge containing one of the two suspect
stations**.

| pair | hops | contains | result | failures |
|---|---|---|---|---|
| paris↔falkenstein | 1 | neither | **22/23** | ordering only |
| **helsinki**↔paris | 1 | helsinki | **22/23** | ordering only |
| **nuremberg**↔falkenstein | 1 | nuremberg | **22/23** | ordering only |
| helsinki↔nuremberg | **2** | both | 17-21/23, ×4 runs | ordering, content, re-advertise, first-publish |

**Both suspect stations appear in a clean direct-edge run.** Neither is the
cause. Three direct-edge pairs across three geographies behave identically, and
the only variable left standing is hop count.

Per symptom:

| symptom | 2 hops | 1 hop |
|---|---|---|
| content readable from the far station | **late in 4 of 4 runs** | first attempt, 3 of 3 |
| re-advertise restores route | FAIL 2 of 4, permanent when it fails | ok 3 of 3 |
| first single publish | FAIL 2 of 4, one direction | ok 3 of 3 |

**Content lateness is the strongest of the three**: it failed every two-hop run
and no direct-edge run. The other two are intermittent, so three clean controls
leave roughly a one-in-eight chance each of a false all-clear. Called
**MEASURED** for content, **well-supported but not proven** for the other two.

**INFERRED, still:** that the three share one cause. They are correlated with
hop count and with each other, which is suggestive and is not a root cause. The
propagation path between two stations with no direct edge is where to look, not
what to blame.

This matters more than the numbers suggest, because **the fleet has exactly one
genuine multi-hop pair.** Every other core pair is a single hop. Any harness not
deliberately wired to helsinki↔nuremberg has been measuring one hop while
reporting two, for as long as this fleet has existed — and the three controls
above are themselves single-hop measurements that would have read as "the mesh
is fine".

### 3.3 Per-publisher delivery order is not preserved, and the guide is ambiguous about whether it should be — MEASURED

25 events from **one publisher**, published in order, arrive with 68-121
inverted pairs out of 300. Reproducible across **seven runs on four distinct
station pairs**, at both hop counts, without a single clean run.
It went unmeasured until now because every existing drain folds payloads into a
`sets:set`, which discards order by construction.

⚠ **Corrected after adversarial review.** This section first claimed nothing in
the SDK documents ordering "in either direction". That is false, and one grep
refutes it. `docs/guides/PUBSUB_GUIDE.md` has a **Delivery guarantees** section:

> - **Per-publisher ordering** — `seq` is monotonic per publisher per pool.
>   Subscribers can detect gaps if they care.
> - **Cross-publisher ordering** — none.

So the decision is narrower and more concrete than "invent a policy". The bullet
is **titled** per-publisher *ordering* while its body promises only a monotonic
`seq`. A reader who takes the title at face value is promised delivery order and
does not get it — on that reading the measured inversions are a **broken
documented promise**, i.e. a defect. A reader who takes the body literally is
promised only a gap-detectable counter, which is exactly what ships.

**Also correcting the severity.** Every delivered event carries `seq` in `Meta`,
so a consumer that needs order has the repair tool on every message. "Any
consumer will assume order and be silently wrong" overstated it.

**The decision is one sentence in one bullet:** does per-publisher ordering
promise delivery order, or only a monotonic sequence? If the former, this is a
defect. If the latter, say so in the title as plainly as the cross-publisher
bullet already does.

⚠ Do **not** assume the multi-hop work in §3.2 removes this. Reordering was
measured across a direct edge too.

### 3.4 State accumulates without release — MEASURED, partly

- `unsubscribe/2` is a **local filter only**. The SDK's own doc says the wire
  subscription "persists for the pool's lifetime". A service that subscribes per
  session accumulates permanent station-side state.
- The station Bloom saturates at roughly 1,300 topics with no documented way to
  clear it.
- Frankfurt's 12,392 peering workers (§2.2).
- A pool restarted under `child_spec/3` comes back **empty** — subscriptions,
  advertises and stream advertises all lived in the dead pool's state, and
  application-held refs are silently stale.

**INFERRED:** these are the same shape — the system is much better at
establishing state than at releasing or re-establishing it. That is the
lifecycle half of the same weakness as §3.1: it is not that things break, it is
that nothing notices they have.

---

## 4. What shipped this session

| | where | effect |
|---|---|---|
| Two-service cross-station torture, 23 rounds | macula-e2e | the instrument that produced §3.2 and §3.3 |
| Reachability + identity-collision probe | macula-e2e | catches a repointed retired station name |
| Wire tripwire (kernel backlog vs dispatch counter) | macula-station | **live and verified on hardware**, 93 checks in 15 min |
| Dial-futility and relay-ping miss counters | macula-station | a failed dial and a failed ping now cost a counter |
| Realm-side staleness verdict | macula-realm | a mute station is now visible from outside itself |
| `getstat/2` returns `not_implemented` | macula | removes a trap laid for exactly this work |

**Known incomplete:** the healthcheck retarget is inert. Every station compose
overrides the image `HEALTHCHECK` with `/status`, which is hardcoded 200 and
cannot fail. And `unless-stopped` restarts on exit, not on unhealthy, so even a
red healthcheck acts on nothing today.

---

## 5. Version posture — MEASURED

macula is **8.0.0**. Two of roughly forty-five consumers resolve it. The fleet
runs 7.1.0. Twenty-two `hecate-*` services are held on 7.x by **one line** in
the published `hecate_om 0.9.0`, whose local tree already says `~> 8.0` and has
not been published.

Nothing breaks on 8.0.0 in macula-station, macula-e2e or macula-torture — every
`call/5` site matches generically, verified by grep. The cost of the skew is
measured, not argued: with both endpoints on 7.0.0, a handler's refusal reason
does not reach the caller. **INFERRED:** the evidence does not separate
loss-in-transit from SDK encode/decode, so "does not survive a hop" would
attribute a mechanism the test cannot see. The consequence is the same either
way — **no hecate service can currently tell a caller why it said no.**

Separately, `hecate-warden` and `hecate-sentinel` build trees still carry macula
**5.1.0**, two majors behind the wire the fleet speaks. Both are live
participants. **UNKNOWN** whether they are functioning or quietly degraded.

---

## 6. Honest gaps in this assessment

- **Frankfurt's 12,392 workers are unexplained.** Not investigated.
- **The multi-hop cause is inferred, not found.** Three symptoms, one suspected
  path, no root cause.
- **Link loss and replay have zero coverage.** `macula_e2e_fault.erl` is a
  complete docker-level fault-injection module (pause, stop, restore) that
  **nothing calls**. The fleet auto-rolls on every push, so link loss is a daily
  event, not an edge case, and no test has ever asserted what survives it.
- **No test opens a pool through `child_spec/3`**, which is the only lifecycle
  production uses.
- **Content has no documented durability bound.** `put_content` returns `ok`
  before the blob is readable elsewhere, and how long "before" is has never been
  specified or measured beyond "it arrives on the retry".
- **The realm-side check has never fired in anger.** It is tested, not proven.

---

## 7. The one-line verdict

> Macula is a working mesh with a mature happy path and an immature nervous
> system: it is far better at doing the work than at knowing whether the work
> happened.
