# DESIGN: the realm-seam E2E gate

> **This exists so that a BEAM client can call mcl-echo through a real station,
> authorized by a delegation a real macula-realm issued, and get back exactly the
> value THIS RUN sent, on a machine that has never heard of the public fleet.**

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

The artefact, never a step that ran, and the artefact has to be **this run's**.

Not exit 0. Not "the harness completed". Not "the service advertised". Not
`healthy_links > 0` (necessary, not sufficient, macula#18). **And not `{ok, _}`**,
which is the shape that lets a broken handler through: `macula_station_call_station_SUITE`
asserts `{ok, _}` on a `_dht.find_record` for a key nothing ever put, so it passes
on "a well-formed reply came back" whatever the content.

### ⚠ A constant payload asserts nothing about this run

mcl-echo **returns the payload unchanged** (`mcl_echo_mesh_rpc:handle_request/2`),
so the artefact is whatever the caller sent. Assert a constant and a cached
answer, a replayed record or a fabricated reply matches exactly as well as a real
one: the assertion carries no information the caller did not already have, and
break 4 below becomes unfalsifiable, since the only way to fail it is to break the
echo on purpose.

**So the call sends a freshly generated random value on every run and asserts the
reply carries exactly that value back.** That is what turns "a well-formed reply
came back" into "this reply came from something that saw this run's request".

⚠ **The reply is not term-equal to what was sent, and that is the codec, not a
defect.** Send `#{<<"ping">> => Fresh}` and it comes back as
`#{{text,<<"ping">>} => Fresh}`: the key tagged, the value not. So the assertion
reads the value AT its key. A whole-term comparison fails against a perfectly
healthy service, which costs an hour and reads like a product bug.

## 3. ⚠ The ordering, which is the crux

`MaculaRealm.Mesh` derives its seed list **once, at `init/1`**, and **refuses an
unpinned list outright**. Every seed must carry its `expected_node_id` (D5). So
the station's identity has to exist before the realm application starts, and the
station's port is ephemeral and not knowable in advance.

The order is therefore fixed and is not a matter of taste:

```
0. settle the PROFILE and the PUZZLE, before any of it
     - ONE crypto profile, named as a value, set on every node: the station
       peer, the realm node, mcl-echo and the client pool. See 3d.
     - puzzle_enforcement = enforce on the station, which is what the fleet
       runs, so the client's identity must be GROUND, not merely generated.
       See 3e.
0b. mint BOTH keys, before anything boots
     - a foundation keypair; its key id goes on the station at step 1
     - the REALM SIGNING key:
         {ok, K} = macula_node_keys:generate(realm, Profile, #{})
         ok      = macula_node_keys:save(Path, K)
         KeyId   = macula_node_keys:key_id(K)
       Profile MUST be MaculaRealm.Identity.profile(), and Path MUST end
       up mode 0600 or 0400. See 3b, this is a trap.
1. spawn the station          -> with macula app env `foundation_key_ids'
                                 set to the foundation key id, BEFORE
                                 macula starts
2. read back its identity     -> listen_addr/1 (address + ephemeral port)
                                 pubkey/1     (32-byte node id)
3. PUT the trust list         -> foundation-signed, pairing the realm id
                                 with the realm signing KeyId from step 0b
4. force a trust refresh      -> and ASSERT trust_pairs is populated; 3c
5. configure the realm        -> on the REALM's node, BEFORE its app starts:
                                 :station_seeds  (from step 2)
                                 :realm_key_path (Path from step 0b)
6. start the realm app        -> it LOADS the key at step 0b, does not mint
7. ASSERT the loaded key      -> RealmSigningKey.key_id() =:= KeyId.
                                 Do not trust the load. See 3b.
8. realm issues the chain     -> org_directory (realm-signed)
                                 + procedure_delegation (org-signed, names
                                   mcl-echo's node id)
9. boot mcl-echo on mcl_om    -> it resolves the chain and advertises
10. client pool calls echo    -> send a FRESH random value, assert the reply
                                 carries exactly it, read at its key (2)
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

### ⚠ 3b. TWO things are called "the realm key". Read the right one.

`macula-realm` holds two unrelated objects under that name, and matching on the
name gets you the wrong one. `RealmSigningKey`'s own moduledoc warns about it.

| | `GuideRealmLifecycle.RealmKey` | `MaculaRealm.Identity.RealmSigningKey` |
|---|---|---|
| what | `K_realm`, a **256-bit symmetric** key | the **D25 signing** key |
| minted | `:crypto.strong_rand_bytes(32)`, sealed AES-256-GCM | `macula_node_keys:generate/3` |
| lifecycle | event-sourced, `realm_key_rotated_v1` | **load-or-generate from a file** |
| for | wrapping per-file content keys for realm licenses | signs `org_directory`; its public half is the trust pin every provider and caller pool holds |

**`K_realm` is symmetric. It cannot sign and has no key id**, so it cannot be
what a trust list pairs a realm id to. **The one this design needs is
`RealmSigningKey`**, and because it is load-or-generate from
`:macula_realm, :realm_key_path` it CAN be minted by the test up front. That is
why step 0b needs no realm boot.

#### ⛔ The trap: the load fails silently and mints a different key

`load_or_generate_and_cache/0` is `case :macula_node_keys.load(path, :realm,
profile) do {:ok, k} -> k; {:error, _} -> generate_and_persist(...) end`. **The
error is discarded.** `RealmSigningKey` logs when the SAVE fails and never when
the LOAD does.

`macula_node_keys:load/3` has five refusal paths, and every one lands in that
silent branch: `key_file_permissions`, `bad_key_file`, `{wrong_purpose, _}`,
`{wrong_profile, _}`, `{wrong_algorithms, _}`. The permission gate is
`owner_only_read`, `Mode band 8#077 =:= 0`, so **the key file must be 0600 or
0400**.

A key file with default permissions, or minted under a different crypto profile
than the realm is configured for, therefore gives you a realm that **boots
clean, reports nothing, and holds a different key id than your trust list
pins**. It surfaces later as an unverifiable chain, nowhere near the cause.

Three cheap defences, all of them required: `chmod 0600` the file, mint under
`MaculaRealm.Identity.profile()`, and **assert at step 7 that the booted realm's
`RealmSigningKey.key_id()` equals the key id published at step 0b.** That last one
is this document's own rule applied to its own setup: do not trust a step that
ran, assert the artefact.

### ⚠ 3c. The station's trust list is a DHT record, not configuration

`macula_dht_server:newest_trust_list/1` flatmaps over
`macula_foundation:live_key_ids()` and looks up
`macula_record:foundation_realm_trust_list_key(KeyId)` for each. `live_key_ids/0`
is `application:get_env(macula, foundation_key_ids)`, so **with nothing
configured it returns `[]`**, the flatmap iterates nothing, `refresh_trust_list`
takes its `error` branch and `trust_pairs` stays `undefined`.

With no trust pairs no realm is checkable and `macula_dht_slots:place_kind/2`
falls through to `unchecked` for every advertisement. **A gate that skips step 1
therefore measures the unchecked slot path and never the production one**, and
would not notice a regression in the path the fleet actually uses. Same shape as
every other adjacent-object gate we have found this week.

`?TRUST_REFRESH_MS` is **one hour**, and the PUT at step 3 necessarily happens
after the station booted, so step 4 is not optional. It is a plain
`handle_info(refresh_trust_list, _)`, so forcing it is an ordinary message send
through the harness's `rpc/4`. **Assert `trust_pairs` is populated afterwards.**
That is an explicit reading. Do not sleep and hope.

### ⚠ 3d. ONE profile, named as a value, asserted

Nothing in the seam negotiates a crypto profile: every party has to be told the
same one, and two halves disagreeing surfaces as an unverifiable chain nowhere
near its cause, which is the failure 3b exists to prevent.

- `macula_station_test_cluster` pins **`pq_hybrid`** on the station's peer node,
  before `macula` starts, because `macula_app` refuses to start without exactly
  one `crypto_profile`.
- `RealmSigningKey` takes **the deployment's configured** profile, pq_hybrid or
  pq_pure. It is not a constant to be read off the module.

So "mint under `MaculaRealm.Identity.profile()`" is not enough on its own: it
says *match whatever the realm happens to be configured for*, and the realm is
configured by this harness. **Name the value, set it on every node, and assert
it** on at least the station and the realm, the two that mint keys.

### ⚠ 3e. The puzzle: the harness default is the opposite of the fleet

`macula_station_config` defaults `puzzle_enforcement` to **`off`** when the key
is absent. **All six fleet stations run `enforce`**, confirmed on disk per
station on 2026-09-23, each box's bind-mount source read from `docker inspect`
and sha256'd against the repo's copy.

A gate that inherits the default therefore **skips the puzzle check on every
inbound handshake while looking green**, and would not notice a regression in a
path every production connection takes. This is section 3c's own argument, one
level along: an adjacent-object default that quietly measures the wrong path.

So: set `enforce` explicitly, assert it, and **grind the client's identity key**
rather than generating one, since an unground node_id is refused with
`puzzle_invalid` under enforce. The difficulty is **8**
(`-define(PUZZLE_DIFFICULTY, 8)` in `macula_node_keys`, and the harness pins the
same 8); about 72 ms of grinding. The raise to 12 is pending and is not this
gate's business.

## 4. The breaks this gate must fail on

Green proves nothing by itself; anything passes when things work. Each break cuts
exactly one link, so the gate cannot pass for an adjacent reason.

| # | Break | Expected |
|---|---|---|
| 1 | withhold the realm's delegation | refusal, **not a hang** |
| 2 | issue the delegation to the wrong node id | refusal |
| 3 | stop the service after it advertised | refusal |
| 4 | **the reply does not carry THIS RUN's value** | assertion fails |
| 5 | **delegation past its expiry** | refusal, `authorization_outlived` |

**(4) is the one that matters most**: it is the only break a `{ok, _}` gate sails
straight through, so it is what proves this gate is not the old one. Because
mcl-echo echoes what it is given, the way to drive it is to have the caller
compare against a value the service never saw: assert the reply carries the
value sent by THIS run, and a stale, replayed or fabricated answer fails it. A
constant payload cannot express this break at all, which is why section 2
requires a fresh one.

**(5) is a security case, not tidiness.** The chain is time-bounded and
`macula_record:verify_authorization/3` enforces
`expires_at(Adv) =< min(Dir, Del)`. A gate that accepts an expired delegation is
a hole nothing else in the estate would catch.

⚠ Bound expiry **relatively** and drive it with explicit readings. An absolute
expiry plus a sleep is a flaky test waiting to happen.

**There is no break for the gate's own network, because this gate has no
network to misconfigure.** The stations are spawned as BEAM peer nodes on one
host by `macula_station_harness`, so there is no compose file, no bridge and no
container. The hazard that break was written for is real and recorded elsewhere,
in mcl-echo's `deploy/docker-compose.yml`: a bridged container with no IPv6
"connects and then sits there with no healthy links, looking fine". **It applies
to a containerised mechanism, and this is not one.** If this gate is ever moved
to containers, that break comes back and needs a fact to read rather than a
timeout to wait for.

What survives from it, and is in section 2 already: the gate must never pass on a
timeout, and never on `healthy_links > 0`, which is macula#18, known necessary
and not sufficient.

## 5. Out of scope, deliberately

- **Fixing macula-e2e's existing ~50 cases so they pass on 11.x.** Follow-on, and
  genuinely not blocking: they come back cheaply once the seam exists, because
  what they need is what the seam builds, a pinned seed and a D25 chain in the DHT.
  ⚠ **Do not confuse this with MOVING THE DEPENDENCY, which was blocking and is
  done.** The repo pinned `{macula, "~> 10.5"}`; handshake `-define(VERSION, 3)`
  first ships in **v11.0.0**, so a 10.5 client is closed with
  `unsupported_version` by any 11.x or 12 station and the seam could not run at
  all. The two were one bullet here and that is how a blocker ended up in an
  out-of-scope list. They are separate jobs: the dependency is now `~> 11.4` with
  the station apps at an exact macula-station sha, and the ~50 are still waiting.
- `macula`'s own CI not running CT at all. Separate package, separate owner.
- Fixing `macula_station_call_station_SUITE`'s `{ok, _}`. Belongs to the station's
  owner.
- Fixing the realm's IPv6 seed parse. See 3a.

## 6. The prerequisite that blocked this, and how it was met

Step 1 could not be written at all while **no repo except `macula-station` could
spawn a station**: `macula_station_test_cluster` and `macula_station_stub_tier`
lived in `apps/macula_station/test/`, rebar3 does not compile a dependency's
`test/` directory, and macula-station is not on hex, so a git dep did not help
either. Hand-rolling a station boot in this repo would have been ~700 lines and a
second copy of one judgement, rotting silently the moment the station's boot
contract changed.

**It was fixed where it belonged.** `macula-station` now ships
`apps/macula_station_harness`, holding both modules, so any consumer gets them on
its code path. This repo depends on it by `git_subdir` at an exact sha.

### ⚠ On the git dependencies

They are pinned to **exact shas, never branches**, which is a scoped exception:
the rule against a committed git dependency on `macula` exists so that a LIBRARY
never ships one, and this repo publishes to no registry. An earlier pin here
named a branch that has since been merged away, so it resolved on one machine and
on no other, and a fresh clone failed in a way that read as a broken repo rather
than a stale pin. **A sha goes stale silently; a branch goes stale loudly and
later.** Neither is caught by anything automatic here on purpose: a check that the
pin is current would go red on every upstream push and be switched off within a
week. **Instead the suite prints the versions it built against in its run output,
so a green run always names what it actually tested.**
