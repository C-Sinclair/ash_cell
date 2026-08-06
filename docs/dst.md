# Deterministic Simulation Testing for AshCell

**Status:** proposed
**Date:** 2026-08-06

---

## 1. Why

Every defect found so far was a *schedule*, not a logic error:

| Bug | The schedule that caused it |
|---|---|
| Caller crashed on bind | cell died between registry lookup and the `repo_pid` call |
| Close yanked a live cell | binder arrived between the bind count reaching zero and the close landing |
| Quarantine never consulted | activation retried a failure that was never transient |
| Missing key wrote plaintext | key destroyed between one activation and the next |

The suite was at 101 tests and green while all four were live. That is not a gap in
coverage; it is a gap in *method*. An example-based test picks one interleaving out of an
enormous space, and it is almost never the interesting one. Every bug above was found by
clicking around a demo, which is a slow, unreliable way to sample schedules.

DST samples them deliberately, and — the part that matters — reproducibly. A failing seed
is a bug report you can replay on demand instead of a log you read for four hours.

## 2. The central move

celld's framing is the right one and transfers almost unchanged:

> the clock, the randomness, and the object store are interfaces, and a simulator drives
> the core

Their pure decision core has no I/O, and **V8 deliberately stays outside the simulation
because V8 is not deterministic.**

The equivalent for us is sharper than it first looks:

> **SQLite stays out of the simulation.**

That is not a compromise. SQLite is the part we are *least* worried about: it is the most
tested database in the world, it is single-writer by construction, and none of our bugs
were in it. What we are worried about is everything wrapped around it — who owns a cell,
who may write, what happens between two events. That layer is small, and it can be pure.

So the simulation covers the **coordination protocol**: leases, generations, drain
ordering, bind and close lifecycle, quarantine, migration gating. It does not cover SQL,
the NIF, or the filesystem.

## 3. Separating decisions from effects

Today the decisions live inside GenServers, tangled with the effects they cause. The
refactor is to split them:

```elixir
# Pure. No processes, no time, no I/O. Deterministic by construction.
@spec step(state, event) :: {state, [effect]}
```

Events are things that happen *to* a node (`{:bind, tenant, ref}`, `{:store_reply, ref,
result}`, `{:alarm, :renew_lease}`, `:drain_requested`). Effects are things the node wants
done (`{:store_put, key, body, opts, ref}`, `{:set_alarm, name, ms}`, `{:reply, ref,
result}`, `{:open_cell, tenant}`).

The real GenServers become shells that translate messages into `step/2` and then perform
the effects. **A shell must contain no decisions.** That is the discipline the whole
approach rests on: any `if` in a shell is untested by the simulator, and the divergence
will not announce itself.

This is a real refactor of `Manager`, `Drain`, and the lease logic. It is worth doing on
its own merits — the decision logic becomes readable and unit-testable — but it should be
costed honestly rather than described as free.

## 4. Architecture

```
AshCell.Core.Node          pure: step(state, event) -> {state, effects}
AshCell.Core.Store         pure: the model of a conditional-write object store
AshCell.Sim                the driver: virtual clock, seeded PRNG, event queue
AshCell.Sim.Faults         what can go wrong, and how often
AshCell.Sim.Invariants     what must remain true after every single step
AshCell.Sim.History        the log a failure is explained from
```

The simulator is **one process**. No BEAM scheduling is involved, so determinism is not a
property we have to fight for — it falls out of the core being pure and the driver being
single-threaded. This is the reason not to run real GenServers under simulation: the moment
a real process is involved, the BEAM scheduler becomes an uncontrolled source of ordering
and the seed stops being a reproduction.

### The loop

```
1. Pop the earliest event from the queue (ties broken by the seeded PRNG,
   not by insertion order -- ties are exactly where interesting orderings hide).
2. Apply it: {state, effects} = Core.Node.step(state, event).
3. Check every invariant against the whole world. Fail immediately, with history.
4. Turn each effect into future events, with fault injection and a
   randomised delay drawn from the PRNG.
5. Repeat until the queue is empty or a step budget is exhausted.
```

Checking invariants after *every* step rather than at the end is what makes failures
diagnosable: the history ends one step after the violation, not thousands.

## 5. Faults

celld injects "CAS races, lost responses and latency, clock drift between nodes, crashes at
each await point, adversarial handler behaviours". Ours, mapped to what can actually happen
here:

**Store**
- conditional write refused (`412`) — the fencing path, and the one most worth hammering
- request lost after the store applied it (the ambiguous retry: did my PUT land?)
- reply lost, reply delayed, replies arriving out of order
- transient `5xx`, then success
- latency drawn from a distribution with a long tail, not a constant

**Nodes**
- crash at any await point, losing all in-flight state, restarting from the store only
- restart with a stale view of ownership
- pause (simulating a GC pause or VM migration) long enough to lose a lease without noticing

**Clocks**
- per-node drift and skew
- a wall-clock step forwards or backwards mid-run (NTP correction)
- monotonic time that advances at a different rate per node

**Callers**
- a bind that never releases (the LiveView holder case)
- a caller that dies while bound
- a close racing a bind, both racing a drain

The fault schedule is drawn from the same seeded PRNG as the ordering, so it is part of the
reproduction.

## 6. Invariants

These are the specification. Getting them right matters more than the simulator does.

**Safety** — must hold after every step:

1. **One writer per generation.** No two nodes ever believe they hold the same tenant at
   the same generation. (celld's "two writers never coexist in one epoch".)
2. **No acknowledged write is lost.** Anything acked to a caller is recoverable from the
   store, at or above the generation it was acked at.
3. **Snapshot precedes release.** A lease is never released while local state is newer than
   the newest snapshot in the store. This is the drain ordering bug expressed as a property,
   and it is the one I would most want a machine to check.
4. **No plaintext fallback.** A cell configured for encryption never opens without a key.
5. **A bound caller never sees a dead cell.** If a bind succeeded, the cell stays usable
   until that binding is released or the caller dies.
6. **Quarantine is sticky.** A tenant that failed activation is not retried until released.
7. **Monotonic generations.** A tenant's generation never decreases.

**Liveness** — must eventually hold, given the faults stop:

8. Ownership settles on exactly one node after a crash.
9. Every armed alarm eventually fires (lease renewal, drain deadline).
10. A drain terminates, whether or not it quiesced.
11. A quarantined tenant, once released, can activate again.

Liveness is checked with a bounded-time assertion rather than a true limit: "within N
simulated seconds of the last fault, this becomes true."

## 7. Seeds

A run is `{seed, config}` and nothing else. A failure prints:

```
DST failure: seed=8134 steps=2917 invariant=snapshot_precedes_release
  mix dst --seed 8134
```

Seeds that have ever failed go into `test/dst/regressions.exs` and run on every CI build,
forever. celld's phrasing is the right policy: *keep the seed until the bug is dead.*

Two run modes:
- **CI**: a fixed set of seeds plus the regression corpus, bounded wall-clock.
- **Soak**: unbounded random seeds, run nightly or on a spare machine, reporting new
  failures. This is where new bugs actually come from.

## 8. Testing the tests

The most valuable idea on celld's page, and the easiest to skip:

> we run deliberately broken variants of the protocol against the properties, and the
> properties must find the damage

An invariant suite that has never caught anything is indistinguishable from one that
cannot. So the simulator ships with a set of **deliberately broken cores**, each with one
known defect, and a meta-test asserting that each is caught — and by which invariant.

Seed the mutant set with the bugs already found, because we know they are real and we know
the properties should catch them:

| Mutant | Must be caught by |
|---|---|
| release lease before snapshot | #3 snapshot precedes release |
| open without a key when key missing | #4 no plaintext fallback |
| close without waiting for quiescence | #5 bound caller never sees a dead cell |
| skip the quarantine check | #6 quarantine is sticky |
| trust the lease instead of the conditional write | #1 one writer per generation |
| ack before the store confirms | #2 no acknowledged write is lost |

If a mutant survives, the invariant is decoration. That check is worth more than a hundred
extra seeds.

## 9. What this will not catch

Stating the limits so the green tick is not over-read:

- **Anything inside SQLite**, deliberately. Corruption, WAL edge cases, and SQLCipher
  behaviour need real files and real bytes. Those stay in the existing suite.
- **Real S3 semantics.** The store model encodes what we *believe* conditional writes do.
  If that belief is wrong the simulator will confidently agree with us. Needs a conformance
  test running the same operation sequences against MinIO, R2, and Tigris — providers
  differ, and "S3-compatible" is doing heavy lifting in our correctness story.
- **The shells.** Any decision that stays in a GenServer is outside the simulation.
- **Performance.** Virtual time says nothing about wall-clock behaviour.
- **Ash and Ecto.** The simulator models a cell as an opaque thing that opens, serves, and
  closes.

## 10. Staging

| Stage | Delivers | Effort |
|---|---|---|
| **0** | Store model + invariants #1–#3, driven by scripted sequences rather than a scheduler. Proves the properties can express what we mean before anything is refactored. | ~2 days |
| **1** | Extract `Core.Node` from `Manager`/`Drain`/lease logic; shells become translators. | ~4 days |
| **2** | The simulator: virtual clock, seeded PRNG, event queue, per-step invariant checks, history dump. | ~3 days |
| **3** | Fault injection across the taxonomy in §5. | ~2 days |
| **4** | Mutant cores and the meta-test. | ~2 days |
| **5** | `mix dst`, regression corpus, CI wiring, soak mode. | ~1 day |

Stage 0 first, deliberately: writing the invariants against a store model is cheap, and if
they turn out to be hard to state precisely, that is a finding about the design rather than
about the tooling — and it arrives before any refactor.

## 11. What Stage 0 actually found

Stage 0 is built (`test/dst_stage0_test.exs`, 13 tests). It took a few hours and
found four things, three of them protocol defects rather than test problems. That is
the argument for the rest of the plan.

### Generation-keyed durability does not fence

The headline. `AshCell.Replicator` keys durability writes by **lease generation**, and
the design notes claim this fences a displaced writer. It does not.

A fenced writer at generation 1 writes to a key its successor at generation 2 never
touches. The conditional write succeeds, the caller is acknowledged, and the data is
superseded the instant the successor snapshots. Nothing is refused anywhere, so
nothing is fenced. Generation-keyed durability only fences against a successor that
reuses the same generation — which is exactly what a successor never does.

The fix is a per-tenant **transaction number shared by every owner, past and present**,
with each writer using its own local counter rather than reading the store. A displaced
writer's counter is stale by construction, so its next write collides with one the
successor already made and it discovers it has been fenced before acknowledging
anything. This is why celld keys LTX segments by TXID rather than by epoch — a
distinction the earlier write-up glossed over.

**This affects shipped code**, not just the model. `AshCell.Replicator.snapshot/3` takes
a generation and must take a txid.

### Generations cannot be derived from snapshot count

Two successive owners with no writes between them were allocated the same generation. A
generation that repeats is a fence that does not fence. Generations must be allocated
from a counter the lease claim advances, since the lease is the only thing written on
every ownership change.

### "One writer" took three attempts to state

- *No two nodes at the same generation* — too weak; split-brain holders sit at
  different generations and nothing fires.
- *At most one node holds a tenant* — too strong; a fenced writer that has not noticed
  yet is the situation the whole design exists to make safe.
- *A node never holds a generation it did not win* — correct. The distinction is not
  how many nodes believe they hold the tenant, but whether the belief was **earned**.
  Beliefs may be stale; they may not be invented.

Each correction was forced by a mutant surviving. An invariant nobody has attacked is
an assertion about the author's confidence, not about the system.

### Per-step checking is not an optimisation

The release-before-snapshot mutant passes an end-state check: by the time the drain
finishes, the snapshot has landed and the final state is spotless. The bug is a
*window*, so the check has to be able to see windows. The Stage 0 test asserts both —
caught per-step, invisible at the end — so the point cannot be quietly lost later.

## 12. Why this before replication

LTX replication adds capability to a system whose concurrency we have just demonstrated we
do not fully understand. Four schedule bugs in one afternoon of clicking is a strong signal
about where the risk lives, and page-level replication makes the ownership protocol *more*
load-bearing, not less. Better to be able to replay a schedule before adding one.
