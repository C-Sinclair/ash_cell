# DD-06 — The append log and compaction

**Status:** draft
**Date:** 2026-08-26
**Decisions:** [ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md), [ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md), [ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md), [ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md), [ADR-20](../decisions/ADR-20-choose-a-durability-level.md)
**Lands in:** `lib/ash_cell/log.ex` (new), `lib/ash_cell/resource/log.ex` (new), the extraction of the hand-rolled logs in `demos/collab_editor` and `vellum`, and the new `demos/ledger`

## What this is

One data structure, parameterised by a fold: an ordered append-only log inside a cell, with a
**checkpoint** row holding the folded state and a **tail** of entries appended since. Reading is
`checkpoint ⊕ tail`. Compaction folds the tail into the checkpoint — in one `BEGIN IMMEDIATE`
transaction — and optionally truncates what it folded.

It is an extraction, not an invention. `collab_editor` folds Yjs updates, `vellum` folds those plus
an authorship ledger, `vcs` folds a commit DAG. All three are the same operations with different
folds, and each re-derived the truncation-safety argument separately.

The shape below was written *from* those implementations rather than from the idea of a log, which
corrected five things an earlier draft of this document had wrong. They are called out in
**Corrections** so the next reader does not reintroduce them.

## What this proves

- Compaction is atomic: a reader concurrent with a compaction sees either the pre-fold tail or the
  post-fold checkpoint, never a checkpoint with its source entries already gone, and never both.
- The safety argument belongs to the **cell**, not the payload. Same code, different folds: a Yjs
  merge gives a CRDT document; a state-machine reducer gives an event-sourced aggregate; an
  append of authorship tuples gives `vellum`'s ledger. Any fold, one proof.
- **`checkpoint ⊕ tail == fold(all entries)` at every compaction threshold**, checked by property
  test over generated histories. This is the invariant everything else rests on.
- A compaction interrupted anywhere — process kill, cell taken mid-transaction, node loss — leaves
  the log readable and the folded state correct
  ([ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md) established this for
  transactions generally; this shows it for a specific structure).
- **The compaction threshold is a dial between write cost and read-model freshness, not two
  architectures.** At `entries: 1` the tail is always empty, so a checkpoint column is exact and
  cross-aggregate queries need no overlay — which is identical to "update the projection in the
  append transaction". At `entries: 500` writes are cheap and those queries are stale by up to the
  tail. One mechanism, one number.
- Log growth is bounded by the compaction policy rather than by history *when truncation is on*;
  when it is off, **read** cost is still flat in history, because a read only touches
  `seq > through_seq`.
- CQRS and event sourcing need nothing here beyond `expected_version` and idempotent commands: a
  scoped log is an event store, the checkpoint is the aggregate snapshot and the read model, and
  the demo that shows it is [`demos/ledger`](../../demos/ledger/docs/design.md).

## Why it needs a cell

The load-bearing sentence, generalised: *a CRDT converges under concurrent appends, but compaction
is a read-modify-write, and a CRDT does not make a read-modify-write safe — the cell's single
writer does.* Two processes compacting one log against a shared table both read the same entries,
both write a checkpoint, and one truncation removes entries the other's checkpoint did not include.
Advisory locks or a compare-and-swap generation paper over it; a cell removes the concurrency.

The second reason is transactional: the checkpoint write, the truncation, and any guard that must
hold before history is destroyed have to commit together, and they are in one file, so they can.

## Non-goals

- **Not a distributed log.** No partitions, no consumer groups, no cross-cell ordering. A log is
  cell-local and its order is the cell's write order.
- **Not a replacement for the replication path.** Checkpoints here are rows, not the object-store
  snapshots of [DD-02](DD-02-replication-and-ownership.md). The two words collide and the code must
  not — this document says *checkpoint* for the row and *snapshot* only for the object.
- **Not a fold library.** The fold is the application's. Ship perhaps two reference folds as
  examples, not a catalogue.
- **Not exactly-once consumption.** Reading is by cursor and a crashed consumer re-reads. Effects
  on top of that are [DD-08](DD-08-durable-execution.md).
- **Not automatic compaction tuning.** Policy is declared and the application picks; the library
  will not guess.
- **Not a projection subsystem.** There is no separate read model, no projection daemon, no
  checkpoint table for consumers. The checkpoint row *is* the read model — see *Data model*.
- **Not multi-log transactions across cells**, the same refusal as everywhere.

## Corrections to the earlier draft

Each of these was wrong in the first version of this document and is right in both shipped
implementations. They are listed because they are the parts most likely to be re-derived wrongly.

1. **`seq` is not `MAX(seq) + 1`.** After a truncation `MAX(seq)` is NULL, so allocation would
   restart at 1, collide with already-checkpointed sequence numbers, and silently corrupt every
   resume. It is `max(MAX(seq), through_seq) + 1`. Both demos implement this as a `head_seq/1`
   that falls back to the checkpoint.
2. **The fold is seeded by the prior checkpoint**, not a pure reduction over entries. `merged_state`
   applies the checkpoint into a fresh `Yex.Doc` *then* the tail, so the contract is
   `seed(prior) → apply(entry) → dump`, against a mutable accumulator.
3. **One checkpoint row, upserted** — `collab_editor` keys it `"current"`, a scoped log keys it by
   scope. The earlier `retain_snapshots N` option was invented and is dropped; retaining N is a
   different key design that nothing needs.
4. **Compaction needs a guard that can veto it.** `vellum` calls `assert_attributed!/2` before the
   checkpoint write and raises to abort — and that raise, inside the transaction, is what makes
   "the ledger write and the truncation are one transaction" true. Without it `vellum`'s central
   claim is unenforced.
5. **Reading has three outcomes, not two.** A cursor below `through_seq` cannot be served
   incrementally; both demos return `:compacted_past` and the caller asks for the state instead.

Two smaller ones: the head is a `sort: [seq: :desc], limit: 1` read rather than `max(seq)`, because
AshSqlite has no aggregates; and both demos read the *entire* tail into memory during compaction,
which is fine at their thresholds and is a stated risk below.

## Data model

Two tables per log, generated by the extension.

**Entries** — `scope` (see below), `seq`, `payload`, plus any `entry_attributes` the application
declares. Primary key `(scope, seq)`. The extra attributes are ordinary columns, not keys:
`collab_editor` carries `client_id` and `at`, `vellum` an author reference. Without them that
metadata would have to be buried in the payload where it cannot be queried.

**Checkpoint** — `scope` (primary key), `through_seq`, `updated_at`, and *either* a `state` blob
*or* application-declared typed columns. This is the important choice:

- A blob is right when the folded state is not columns — a Yjs document.
- **Typed columns make the checkpoint the read model.** A ledger account's checkpoint holds
  `balance` and `status`, so "every overdrawn account" is an ordinary indexed query instead of a
  fold over every scope. This is why no separate projection table exists.

The checkpoint is never authoritative alone. It is a memo of the fold up to `through_seq`, and the
tail is the correction — so any query reading a checkpoint column without overlaying the tail is
reading a value stale by up to the compaction threshold. At `entries: 1` there is no tail and the
distinction disappears. **This is the single most misusable thing in the design** and belongs in the
generated function docs, not only here.

### Scope: one log per cell, or one per row

`scope` unifies two cases that look like different structures:

```
scoped (scope :account_id)          unscoped (no scope)
entries  PK (scope, seq)            entries  PK (seq)          — scope is a constant
checkpoint PK (scope)               checkpoint PK ("current")
```

Both are needed by things already on the table: `collab_editor` and `vellum` are unscoped (the cell
*is* the document); [`demos/ledger`](../../demos/ledger/docs/design.md) and
[DD-08](DD-08-durable-execution.md)'s per-instance workflow history are scoped. Correctness does not
fork — one cell, one connection, one writer either way. Four things do:

1. **Compaction becomes N compactions.** A cell with 10 000 scopes past threshold is a compaction
   storm holding the cell's only connection. Bounded: at most `compact_batch` scopes per pass
   (default 8), oldest-threshold-first, the remainder deferred. This is the one place the
   flexibility genuinely costs, and the bound is not optional.
2. **The generated API differs in arity** — `state(scope)` vs `state()`, `compact(scope)` vs
   `compact()`.
3. **Every query carries a scope predicate**, so the unscoped case pays a constant-value index
   lookup it does not need. Probably noise; measured rather than assumed.
4. **`seq` changes meaning.** Unscoped it is a cell-wide total order a client can resume from;
   scoped it orders only within a scope, so a cursor is `{scope, seq}` and `:compacted_past` is
   per scope.

`scope` names an attribute of the resource the log is declared on, which is what makes declaring it
on a resource obviously right. An unscoped log declared on a resource is mildly impure — it belongs
to the cell, and the resource is just where it was written down — but that is a smaller wart than a
second DSL location.

### Truncation

`truncate?` defaults to `true`. `collab_editor` deletes what it folded, because bounded storage is
the point. **A ledger must not**: in an event-sourced system the entries *are* the record, and
deleting them destroys the thing the system exists for. With `truncate?: false` the checkpoint
advances and nothing is deleted — storage grows with history, read cost does not, and
replay-from-zero stays local rather than depending on object-store snapshots
([ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)), where a lifecycle rule could
silently delete an audit record.

### Consuming it

```elixir
cell_log do
  log :entries do
    scope :account_id                  # omit for a cell-wide log
    fold Ledger.Folds.Balance          # seed/1, apply/2, dump/1
    truncate? false                    # events are the record
    compact_when entries: 1            # the freshness dial
    compact_batch 8                    # bound on scoped compaction per pass
    before_checkpoint Ledger.Guards.Balances   # may raise to abort
    idempotent_by :command_id          # dedup table, written in the same transaction

    checkpoint_attributes do           # typed read model, instead of a state blob
      attribute :balance, :integer
      attribute :status, :atom
    end

    entry_attributes do
      attribute :posting_id, :string
      attribute :at, :utc_datetime
    end
  end
end
```

Generating the two resources and: `append/3` taking `expected_version:` and returning
`{:ok, seq} | {:error, :version_conflict, actual: n}`, `read_since/2` returning
`{:ok, entries} | :compacted_past`, `state/1`, and `compact/1` returning the stats map both demos
already produce.

**`expected_version` is the one genuinely missing primitive**, and it is worth being precise about
why a single writer does not remove the need for it. The cell removes the *race* — no two appends
interleave. It cannot remove the *stale decision*: a handler that read the aggregate at version 7,
decided, and had version 8 land before it appended. That check is a comparison inside the
transaction, but it is load-bearing and neither demo has it, because neither has concurrent
deciders.

There is deliberately **no `after_append` hook**. An earlier sketch had one for updating a
projection; typed checkpoint attributes make it unnecessary, because there is no second table to
update.

## Trade-offs

- **Checkpoint in a row vs in the object store.** A row keeps compaction atomic; an object keeps the
  file small. Chosen: a row — atomicity is the point, and a cell holding a 100 MB checkpoint is a
  signal the cell is cut wrong ([ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md)).
- **Typed checkpoint columns vs a blob.** Columns make the checkpoint queryable and couple the
  schema to the fold, so changing what the state contains is a fleet-wide migration. Chosen: both,
  declared per log, because `collab_editor` cannot use columns and `ledger` cannot use a blob.
- **Compaction inline vs background.** Inline makes a write occasionally slow; background needs its
  own binding and a way not to race the writer — which, since the cell *is* the writer, means asking
  the cell anyway. Chosen: the cell schedules it against itself, so it is background in latency
  terms and inline in concurrency terms.
- **Bounded vs unbounded scoped compaction.** Unbounded is simpler and can stall a cell's only
  connection for an unbounded time. Chosen: bounded, because an unbounded compaction looks fine at
  demo scale and stalls a real tenant.

## Measurements this must produce

Warm cell, `pool_size: 1` ([ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md)), median of 5:

- **Append throughput** at payload sizes 256 B / 4 KB / 64 KB.
- **Compaction cost vs entries folded** at 100 / 1 000 / 10 000, and **p99 append latency during a
  compaction** — the number that decides whether inline scheduling is acceptable. A **cliff**: the
  entry count at which p99 append crosses 50 ms.
- **The dial, both ends**: append throughput and cross-scope query exactness at `entries: 1` versus
  `entries: 500`. The ratio is the price of an exact read model.
- **Scoped compaction under load**: p99 append latency in a cell with 10 000 scopes past threshold,
  with `compact_batch` at 1 / 8 / 64, to show the bound does what it claims.
- **Read cost vs history with `truncate?: false`** at 10³ / 10⁶ / 10⁷ entries with `through_seq`
  current — flat is the claim; a cliff would falsify it.
- **Scope predicate overhead**: unscoped log versus a scoped log with one scope.
- **File size before and after compaction**, including whether `VACUUM` is needed to reclaim, since
  SQLite's freelist means truncation may not shrink the file — and if it is, that cost is part of
  compaction's.
- **`collab_editor` and `vellum` suites before and after extraction**, to establish it changed no
  behaviour.

## Staging

1. **`AshCell.Log` as plain functions**, unscoped, one fold, no extension. Checkable: the
   `checkpoint ⊕ tail` property test (1 000 generated histories), and a concurrent reader during
   compaction.
2. **Crash matrix.** Kill the cell at each point in a compaction; assert the property afterwards.
   Includes the drain path's `force: true` case.
3. **`scope`, and `compact_batch`.** Checkable: two scopes compact independently; the batch bound
   holds under 10 000 over-threshold scopes.
4. **`truncate?: false`, `expected_version`, `idempotent_by`.** Checkable: a stale version is
   refused; a replayed command posts once across an eviction.
5. **The `AshCell.Resource.Log` extension** and typed checkpoint attributes. Checkable: a demo
   declares a log in ~10 lines and gets both tables, both actions, and a migration.
6. **Extract `collab_editor`.** Checkable: its Elixir suite and `test/browser/convergence.mjs` pass
   unchanged.
7. **Extract `vellum`'s ledger** via `before_checkpoint`. Checkable: the guard and the truncation
   are visibly one transaction.
8. **`fold_version` and recompaction**, then measurements.

## Where it stops

- Ordering is per cell, or per scope within it. Nothing orders across cells.
- **The fold must be pure and deterministic, and nothing checks that.** A fold that calls a network
  makes recompaction non-reproducible and the library cannot tell.
- Payload tiering to the object store is [DD-11](DD-11-collections.md)'s, not built here; until it
  is, an entry is as large as a SQLite blob should be.
- **A checkpoint column read without the tail is stale**, bounded by the threshold. Nothing in the
  type system prevents it.
- With `truncate?: false` the file grows without bound. Cutting the cell per time window
  ([ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md)) is the answer and is not taken here.
- `fold_version` after truncation is a trap: change the fold once the entries are gone and the old
  checkpoint cannot be recomputed. It errors loudly; whether that is enough is unresolved.
- Durability of an append is the cell's, which is
  [ADR-20](../decisions/ADR-20-choose-a-durability-level.md)'s open question. A returned append is
  not necessarily fsynced — most consequential for [`demos/ledger`](../../demos/ledger/docs/design.md).
- No compaction inside a read-only cell, obviously, but a caller might try.

## Open risks

- **Whether `entries: 1` is fast enough to be the default.** If it is, the freshness dial is a much
  less interesting finding than this document assumes, and the doc should be cut back to say so.
  The stage-1 measurement decides.
- **Inline compaction and the read cache** interact: a compaction invalidates projections built from
  the log, which under `persistent_term` is the expensive direction
  ([ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md)). Measure against the ETS store.
- **Reading the whole tail into memory** during compaction, which both demos do. Fine at 500
  entries; a scoped log with a large batch is a different shape.
- Whether one `seq` allocation from a head read holds up under the bulk-write path, which does not
  go row by row.
- **This work is gated on [ADR-22](../decisions/ADR-22-where-the-tenancy-runtime-lives.md)**: a log's
  tables are created by whichever layer migrates a cell, and that seam is not drawn.
