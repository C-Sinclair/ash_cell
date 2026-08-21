# Rollout — over-the-air updates on AshCell

One cell per release channel. Content-addressed blobs in the object store. A pointer
that decides what every device installs next, read constantly and written twice a
week.

    source .envrc                  # exqlite against SQLCipher -- see ../README.md
    mix deps.compile exqlite --force
    mix run -e "Rollout.Seed.run()"
    mix test
    mix run bench/resolve.exs

The design argument, the trade-offs, and the open questions are in
[`docs/prd.md`](docs/prd.md). This file is what the code currently proves.

## The cut

A channel — `myapp/prod`, `myapp/beta`, `myapp/canary` — is one encrypted SQLite
file with one writer. That is neither a tenant (`console`) nor a record
(`collab_editor`) nor a user (`shroud`), but a **coordination scope**: the smallest
thing that has to agree with itself about what is being served right now.

The load shape is the opposite of every other demo here. Writes are deploys; reads
are the whole fleet. So the interesting engineering is entirely on the read path,
and the interesting *correctness* question is whether a fast read path can still be
one that never serves a release the channel has moved off.

## What it proves

| Claim | Where |
|---|---|
| A device check-in resolves to a manifest without writing anything | `test/rollout/resolve_test.exs` |
| A rollback is visible to the very next check-in | `test/rollout/consistency_test.exs` |
| A cached manifest built before a promotion cannot be published after it | `test/rollout/consistency_test.exs` |
| Concurrent readers never see the pointer move backwards | `test/rollout/consistency_test.exs` |
| The pointer and its promotion log commit together | `test/rollout/control_test.exs` |
| Staged rollout is stable per device, and ramping only adds devices | `test/rollout/resolve_test.exs` |
| Unreferenced blobs can be identified, and shared or rollback-reachable ones are not collected | `test/rollout/control_test.exs` |

32 tests in `test/rollout/`, plus the scaffold's own.

## Measured

`mix run bench/resolve.exs` — 32 concurrent devices × 200 check-ins, median of five,
40 releases × 24 artifacts in the cell:

| | Per resolve | Throughput |
|---|---|---|
| Uncached — two Ash reads against the cell | 207 µs | 4.8k resolves/s |
| Cached — `persistent_term` | **0.18 µs** | **5.7M resolves/s** |

Three things worth saying about that ~1,100× rather than just quoting it.

**The uncached number is the honest cost of the read path**, not a strawman: two Ash
reads through the whole framework, which is what a resolve costs if you do it
properly every time. 4.8k resolves/s from one node is not embarrassing. It is just
nowhere near what a fleet needs.

**The cache is not the interesting part; the invalidation is.** A cache in front of a
shared database is a correctness problem, because you cannot know when someone else
wrote. A cell has exactly one writer and it is on this node, so the invalidation is
not a guess. That is the whole argument, and it lives in
[`AshCell.ReadCache`](../../lib/ash_cell/read_cache.ex) rather than here, because it
is a property of cells and not of OTA.

**Widening the pool was the obvious alternative and it does not work.**
[`scripts/read_pool_probe.exs`](../../scripts/read_pool_probe.exs) measures a
realistic filtered join getting *worse* as the pool grows — `pool_size: 8` runs 1.9×
slower than `pool_size: 1` — because per-query overhead dominates and extra
connections on one file add contention rather than parallelism. The read path had to
improve above SQLite, not inside it.

## What "instant" means here

- **Guaranteed.** Any check-in that *starts* after a rollback commits gets the old
  release. That is the linearization point and it is the one that matters.
- **Undefined.** Check-ins in flight at the moment of commit may see either.
  Unavoidable, and harmless.
- **Impossible.** A device already downloading the bad bundle. It holds a manifest
  that is stale by construction. OTA rollback means "stop handing it out", never
  "un-install".

## Where it stops

Named plainly, because the demo is only useful if the edges are.

- **Single node.** Everything above is one node's read path. The `:replicated` and
  `:leased` strategies in [`docs/prd.md`](docs/prd.md) — local reads on many nodes,
  and revoke-before-commit to keep them linearizable — are **designed and not
  built**. The write-availability cost of `:leased` (a rollback stalls for the lease
  TTL if a reader node is unreachable) is the number that work exists to produce, and
  it does not exist yet.
- **No blobs are actually stored.** Artifacts are hashes and sizes; nothing is
  uploaded, and `collectable_blobs/2` returns hashes rather than deleting objects.
  The GC *argument* — that a single writer makes "unreferenced" a query rather than a
  distributed protocol — is tested. Wiring it to `AshCell.ObjectStore` is not done.
- **No install telemetry.** `docs/prd.md` argues it belongs in a separate cell and
  that co-locating it would destroy the read cache. That is an argument, not a
  measurement; the counterexample benchmark is unwritten.
- **Fencing protects the pointer write, not the read.** Under a future `:replicated`
  strategy a partitioned node serves a stale pointer, so a device could be handed a
  release that was rolled back moments ago. This is the workspace's existing open
  problem, and this demo is where it acquires a user-visible consequence.
- **No console.** There is no LiveView; the demo is driven from tests, the benchmark,
  and `iex`.
- **Not modelled at all:** delta and patch generation, signing and attestation, CDN
  edges, device enrolment, and a "no compatible bundle" signal for a client too old
  for anything on offer.

## Layout

| | |
|---|---|
| `lib/rollout/channel/` | the resources inside a channel cell: `Release`, `Artifact`, `Pointer`, `Promotion` |
| `lib/rollout/resolve.ex` | the read path — check-in to manifest, cached per channel epoch |
| `lib/rollout/control.ex` | the write path — cut, promote, ramp, rollback, and the GC query |
| `lib/rollout/schema.ex` | the cell schema, versioned against `PRAGMA user_version` |
| `lib/rollout/cells.ex` | which channels exist. No global registry: a channel *is* its cell, and standing up Postgres to map a name to itself would prove nothing `console` has not already proved |
