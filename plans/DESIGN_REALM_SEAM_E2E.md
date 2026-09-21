# DESIGN: the realm-seam E2E gate

> **This exists so that a BEAM client can call mcl-echo through a real station,
> authorized by a delegation a real macula-realm issued, and get `<<"pong">>` back
> on a machine that has never heard of the public fleet.**

That sentence is the test for everything below. Anything here that does not serve
it does not belong here.

Tier 1 is `macula` (SDK + QUIC NIF), `macula-station`, `macula-realm`, `mcl-om`,
`mcl-echo`. Tiers 2 and 3 are blocked behind this being green, so an absent
harness blocks them exactly as hard as a defect does.

## 1. Why this is hermetic, and why nobody should "improve" it

Two independent reasons. The second one is the one that matters.

1. **It could not use the fleet even if we wanted to.** GitHub-hosted runners have
   no IPv6 egress and the fleet's stations are AAAA-only, so a QUIC connect can
   never reach one. `mcl-om`'s `live-mesh-tests.yml` documents this in its own
   header: on every push the job burned ~18 minutes for a deterministic red, which
   is why it is `workflow_dispatch` only.
2. **A gate that depends on production is not a gate.** It goes red when the fleet
   has a bad afternoon and green when the code is broken but the fleet is fine.
   Hermetic is correct on its own merits. The IPv6 fact merely makes it
   unavoidable.

If the IPv6 limitation is ever fixed by a self-hosted runner, reason 2 still
stands. **Do not point this suite at the real mesh.**

## 2. What it asserts on

The artefact, never a step that ran. The assertion is `<<"pong">>` coming back
from a call that crossed a real QUIC link to a service authorized by a
realm-issued delegation.

Not exit 0. Not "the harness completed". Not "the service advertised". Not
`healthy_links > 0` (necessary, not sufficient, macula#18). **And not `{ok, _}`**,
which is the shape that lets a broken handler through: `macula_station_call_station_SUITE`
asserts `{ok, _}` on a `_dht.find_record` for a key nothing ever put, so it passes
on "a well-formed reply came back" whatever the content.

## 3. ⚠ The ordering, which is the crux

`MaculaRealm.Mesh` derives its seed list **once, at `init/1`**, and **refuses an
unpinned list outright**. Every seed must carry its `expected_node_id` (D5). So
the station's identity has to exist before the realm application starts, and the
station's port is ephemeral and not knowable in advance.

The order is therefore fixed and is not a matter of taste:

```
1. spawn the station          -> macula_station_test_cluster:spawn_cluster/2
                                 gives a peer node with a real QUIC listener
2. read back its identity     -> listen_addr/1 (address + ephemeral port)
                                 pubkey/1     (32-byte node id)
3. set the realm's seeds      -> on the REALM's node, BEFORE its app starts
4. start the realm app        -> now, and not before
5. realm issues the chain     -> org_directory (realm-signed)
                                 + procedure_delegation (org-signed, names
                                   mcl-echo's node id)
6. boot mcl-echo on mcl_om    -> it resolves the chain and advertises
7. client pool calls echo     -> assert <<"pong">>
```

Steps 2 and 3 are where this gets got wrong. Setting the seeds from inside a
running realm is too late, and the realm will not tell you so: `Mesh.pool/0`
simply never leaves `{:error, :not_ready}`, and `/health` stays green anyway
because readiness is "the pool process exists", not "a link is up".

### ⚠ 3a. The env-var route is unusable here, use the config route

`MACULA_STATION_SEEDS` **cannot express an IPv6 address**. `Mesh.seed/2` does
`String.split(host, ":")` and matches only `[h]` (port defaults to 4433) and
`[h, p]`. An IPv6 literal splits into three or more parts and matches **no
clause**, so it raises `CaseClauseError` rather than saying anything useful.

`macula_station_test_cluster` binds its listener to `::1` deliberately, so the env
route is closed to us. Use the other one the same function already offers: the
`:macula_realm, :station_seeds` application env, a list of
`%{host, port, expected_node_id}` maps, which bypasses the string parsing
entirely. Set it on the realm's node at step 3.

This is a defect in its own right and is **not ours to fix here**: the public
fleet is AAAA-only and is headed for addresses rather than DNS, and this parser
can only ever name a station by hostname. Routed to the realm's owner.

## 4. The breaks this gate must fail on

Green proves nothing by itself; anything passes when things work. Each break cuts
exactly one link, so the gate cannot pass for an adjacent reason.

| # | Break | Expected |
|---|---|---|
| 1 | withhold the realm's delegation | refusal, **not a hang** |
| 2 | issue the delegation to the wrong node id | refusal |
| 3 | stop the service after it advertised | refusal |
| 4 | **handler returns the wrong payload** | assertion fails |
| 5 | **delegation past its expiry** | refusal, `authorization_outlived` |

**(4) is the one that matters most**: it is the only break a `{ok, _}` gate sails
straight through, so it is what proves this gate is not the old one.

**(5) is a security case, not tidiness.** The chain is time-bounded and
`macula_record:verify_authorization/3` enforces
`expires_at(Adv) =< min(Dir, Del)`. A gate that accepts an expired delegation is
a hole nothing else in the estate would catch.

⚠ Bound expiry **relatively** and drive it with explicit readings. An absolute
expiry plus a sleep is a flaky test waiting to happen.

## 5. Out of scope, deliberately

- Repinning macula-e2e's existing ~50 cases from `{macula, "~> 10.5"}` to 11.x.
  Separate follow-on item. It does not block this seam and this seam must not
  wait on it.
- `macula`'s own CI not running CT at all. Separate package, separate owner.
- Fixing `macula_station_call_station_SUITE`'s `{ok, _}`. Belongs to the station's
  owner.
- Fixing the realm's IPv6 seed parse. See 3a.

## 6. ⛔ BLOCKED on one prerequisite, and it is not ours

Step 1 of the ordering cannot be written today. **There is no way for any repo
except `macula-station` itself to spawn a station.**

- `macula_station_test_cluster` and `macula_station_stub_tier` live in
  `apps/macula_station/test/`. rebar3 does not compile a dependency's `test/`
  directory, so a consumer gets neither, even with the dep in place.
- `macula-station` is **not published to hex** (it has `ci.yml` and
  `renovate.yml`, no publish workflow), so the dep would have to be a git dep,
  which does not change the above.
- Booting a station by hand from the public app API is not a small thing. It
  needs the ephemeral-port claim with its TOCTOU window, a generated cert and
  key, `macula_bootstrap` `discoverers` wired to a stub tier (an empty
  `outbound_peers` halts the boot with `{error, no_tiers}`), and a long-lived
  guardian process to own the supervisor link, because `peer:call` runs in a
  transient process whose exit would take the supervisor with it.

Reimplementing that in `macula-e2e` is ~700 lines and is precisely the "two
copies of one judgement" pattern we are deleting elsewhere. The second copy
would also rot silently, because nothing would tell it when the station's boot
contract changed.

**The fix belongs in `macula-station`:** promote the harness out of
`apps/macula_station/test/` into a shipped app in the umbrella, so any git-dep
consumer gets it on the code path. That is defensible on its own merits once a
second repo needs to spawn a station, which is now.

This blocks step 1 only. Everything downstream of it (sections 2 to 5) is
unaffected and stands as designed.
