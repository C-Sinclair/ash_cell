# ADR-23 — Merge a branch by fast-forward, or refuse it

**Status:** accepted
**Date:** 2026-08-25
**Deciders:** Conor
**Relates to:** [DD-05](../design/DD-05-time-travel-and-forks.md), `lib/ash_cell/branch.ex`,
`lib/ash_cell/history.ex`, `test/branch_test.exs`, the `branch` demo

## The decision

Merging a branch into its origin succeeds **only** if the origin's database is byte-identical to
the snapshot the branch was cut from. When it is, the branch's file becomes the origin's file and
is shipped. When it is not, the merge is **refused** and both content digests are returned, so the
caller sees the divergence rather than being told only that there was one. There is no
reconciliation of divergent branches — not row-level, not last-write-wins, not per-table policy.

Divergence is measured by a **SHA-256 of the checkpointed database file**, not by the cell's txid
and not by SQLite's file change counter. Both of those were considered and both are wrong here;
the change counter was measured wrong.

## Context

[DD-05](../design/DD-05-time-travel-and-forks.md) specified forks and listed merge as a non-goal,
deferring it to a fold over an append-only log in
[DD-06](../design/DD-06-append-log-and-compaction.md). The `branch` demo needs the round trip —
provision, branch, diverge, merge — because a branching database service without any promotion
path is half a product, and because the *refusal* is the interesting half to demonstrate.

That forced the question DD-05 had deferred: what does merge mean when a cell is table-shaped?

It has a hard answer. Two divergent SQLite databases have no general reconciliation. Two
conflicting `UPDATE`s on one row cannot be merged without a domain rule, and a library that
invented one — newest timestamp, higher txid, branch wins — would be silently picking a winner in
somebody else's data model. The choice was not *which* merge algorithm, it was whether to have one
at all.

## Options considered

### Option A — three-way merge with per-table policy

Let a resource declare a conflict rule and reconcile row by row.

Buys: merges that actually combine two histories. Costs: every table needs a policy; rows deleted
on one side and updated on the other have no correct answer; foreign keys between tables merged
under different rules can be left inconsistent; and the failure is silent — the merge reports
success over data that no longer means what either side intended. Lost because the cost is paid
in wrong data rather than in refusals.

### Option B — last-write-wins on the whole file

Whichever side wrote most recently becomes the origin.

Buys: trivial to implement, always "succeeds". Costs: it is data loss with a friendly name. Lost
immediately.

### Option C — log-shaped merge only

Cells whose state is an append-only op log merge by replaying the branch's ops onto the origin;
everything else refuses. This is DD-06's fold.

Buys: genuinely merges diverged branches, for cells built that way. Costs: it constrains the data
model of anything that wants to branch, and it is a substantially larger piece of work whose
correctness rests on DD-06, which is not built. **Not rejected — deferred.** It composes with the
decision below: fast-forward is the general case, and a log-shaped fold can later widen what
counts as mergeable without changing what a refusal means.

### Option D — fast-forward or refuse

Merge iff the origin has not been written to since the branch point.

Buys: it is decidable, it is correct with no domain knowledge, and the refusal is precise and
actionable. Costs: a branch left open while its origin keeps serving becomes unmergeable, and the
user has to re-branch and re-apply their change. Won.

## Decision and why

Option D, because it is the only one whose failure mode is a refusal rather than wrong data. A
refused merge costs the user a re-branch; a wrong merge costs them rows they cannot identify as
missing. In a system whose entire pitch is per-tenant isolation and single-writer safety, quietly
discarding a tenant's writes is the worst available outcome.

The narrowness is also less of a limitation than it reads as. **This is what Neon's branches
actually do** — a branch is where a migration or a risky change is rehearsed, and what gets
promoted is the change, not a reconciliation of two histories. Neon does not merge branch data
back either; the schema change travels through git and the branch is discarded.

### Why the divergence test is a digest, and not the two obvious numbers

**Not the txid.** The txid counts *shipments*, and the snapshot policy ships on a schedule, so an
idle origin's txid advances while its contents do not. A fast-forward test built on txid refuses
merges that have no conflict — a false refusal on every cell with periodic snapshots enabled,
which is every production cell.

**Not SQLite's file change counter, and this was measured.** Bytes 24..27 of the database header
are documented as incrementing on every write transaction, which is exactly the semantics needed
and is why it was implemented first. It is rollback-journal behaviour. **In WAL mode the counter
does not move per transaction**, because WAL uses the WAL-index and its salts for the cache
invalidation the counter exists to drive. Measured: three consecutive inserts, each followed by
`PRAGMA wal_checkpoint(TRUNCATE)`, left the counter at 2 throughout.

That is not a cosmetic bug. A fast-forward test built on it reports "no divergence" for a
database that has been rewritten, so merge proceeds and **silently discards the origin's writes** —
precisely the outcome this whole ADR exists to prevent. It was caught by
`test/branch_test.exs`, which asserted the refusal before the implementation was trusted.

**So: a content digest.** SHA-256 over the checkpointed file, measured stable across repeated
checkpoints with no writes between them and different after every write. It is O(size), which
sounds worse than it is: `AshCell.Replicator` already reads and PUTs the whole file on every
shipment, so this is a pass over bytes that are read anyway, and cells are small by design.

## Consequences

- **What it rules out.** Combining two branches that both have writes. A branch left open while
  its origin serves traffic will not merge, and the user must re-branch from the current head and
  re-apply. Long-lived branches are therefore not a supported shape; branches are short and
  rehearsal-flavoured.
- **What it makes worse.** Merge cost is O(database size) twice over — once to digest the origin,
  once to copy and ship the branch — where a page-level design would be O(changed pages). It also
  adds a second full-file read to a path that already had one.
- **What stays open.**
  - **Merge is not atomic across disk and bucket.** The origin's local file is replaced, then
    shipped. Being fenced in between leaves the merge on disk and absent from the store, with the
    cell quarantined by [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md)'s fail-closed path.
    That is the right failure — it stops serving rather than serving a state it cannot persist —
    but recovering it is an operator restoring from the last good snapshot.
  - **Schema-only promotion is not implemented.** The common real use — rehearse a migration on a
    branch, then apply the migration to a still-serving origin — is not what fast-forward does,
    and needs its own path.
  - Whether Option C's log-shaped fold should widen this later.
- **What now depends on it.** `AshCell.Branch.merge/2`, `AshCell.merge/1`, the `branch` demo's
  promotion path and its README, and DD-05, whose "Not merge" non-goal is now narrowed to point
  here.

## Evidence

- `test/branch_test.exs`, `"refuses a merge when the origin has advanced, and names both
  counters"` — forks, writes to both sides, asserts `{:error, {:not_fast_forward, _}}` and that
  the origin still holds its own write and not the branch's. This is the test the module exists
  for; it failed against the change-counter implementation.
- `test/branch_test.exs`, `"SQLite's change counter would not have worked, which is why it is not
  used"` — reads bytes 24..27 directly before and after a write plus checkpoint, and asserts they
  are equal. Kept as a regression test on the belief, not on the code.
- `test/branch_test.exs`, `"a shipment on the origin does not by itself refuse the merge"` — the
  counterpart: shipping is not writing, and a periodic snapshot must not block a legal merge. This
  is the test that fails if the digest is ever swapped back for a txid comparison.
- `test/branch_test.exs`, `"the merged state is what the bucket holds, not just what is on disk"` —
  deletes the origin's local file after merging and restores from the shipment. This caught the
  merge shipping as `:no_lease`, because `AshCell.Manager.close/2` drops the in-memory lease and
  merge has to close the origin to replace its file. Without it the merge was a durable no-op
  reported as success.
- Change-counter measurement: `PRAGMA journal_mode=WAL`, `CREATE TABLE`, then three
  `INSERT` + `PRAGMA wal_checkpoint(TRUNCATE)` cycles against exqlite; header bytes 24..27 read 2
  at every step. Digest measurement: same shape, SHA-256 of the file identical across two
  no-op checkpoints and different after each insert.
- **Not verified:** behaviour at database sizes where the digest pass stops being free relative to
  the shipment it accompanies. DD-05 owes a fork-latency-vs-size measurement and this belongs in
  the same run.

## Notes

Prior art is Neon, whose branches are rehearsal environments rather than mergeable histories, and
Git, whose fast-forward-or-refuse is the same decision for the same reason — with the difference
that Git *can* three-way merge, because it knows its content is text with lines.

A revisit should start with Option C, and with whether "promote the schema change, not the rows"
deserves to be a first-class operation alongside merge.
