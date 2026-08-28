# ADR-25 — Do not build record handoff into the library; publish the ordering instead

**Status:** accepted
**Date:** 2026-08-28
**Deciders:** Conor
**Relates to:** [ADR-05](ADR-05-refuse-cross-cell-transactions.md) ·
[ADR-07](ADR-07-opaque-cell-keys.md) · [ADR-08](ADR-08-fence-by-shared-txid.md) ·
[ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md) ·
[ADR-19](ADR-19-the-cell-cut-is-a-choice.md) ·
[ADR-23](ADR-23-merge-by-fast-forward-or-refuse.md) · `test/handoff_probe_test.exs`

## The decision

AshCell does not move records between cells. There is no `AshCell.Handoff`, no new object-store
key, and no cross-cell driver — [ADR-05](ADR-05-refuse-cross-cell-transactions.md) refused a
cross-cell coordinator and this is the same refusal one granularity down. What the library owns
instead is the **ordering**, stated here normatively and demonstrated end to end by
`test/handoff_probe_test.exs` against two real cells and a real bucket:

1. **Reserve**, in the source, in one transaction: move the record to a `reserved` state
   conditional on it being `owned`. After this commit the source still owns the record and still
   serves reads of it, and it no longer accepts writes to it.
2. **Transfer**, in the target, idempotently, keyed by **`{source_cell_key, record_id}`** — the
   record's identity, never the attempt's and never a txid.
3. **Release**, in the source, in one transaction: move the record to `promoted` and record the
   target's cell key. Only after step 2 has succeeded.

**Resolution follows the pointer, and never an existence check.** A reader resolves a record by
reading it in the source: null pointer means the source is the record, a pointer means bind that
cell key instead. The pointer is written by the one commit that is entitled to say the handoff
happened, which is what keeps "where does this record live" and "has this happened" the same
question with one answer.

Two corrections to the shape this was proposed in, both load-bearing:

- **Three commits, not two.** "Target imports, then source marks" leaves the source *writable*
  between the two commits, so an edit landing in that window is imported-over and silently lost.
  The reserve is what removes the window, and it is why the prior art
  (Orleans, Spanner range split, Durable Object migration) stops the source serving writes
  *before* the transfer rather than after it.
- **The idempotency key is the record, not the attempt.** The proposed
  `{source_cell_key, record_id, source_txid}` is wrong twice: a txid counts *shipments* and moves
  on a schedule with nothing to do with the record, and any attempt-flavoured component turns a
  retry after source amnesia into a duplicate rather than a no-op. Both measured; see *Evidence*.

There is deliberately no window in which both cells may write the record, and no reconciliation
of two copies of it. If a design ever needs one, it has gone wrong in the way
[ADR-23](ADR-23-merge-by-fast-forward-or-refuse.md) describes.

## Context

The forcing function is Vellum's second cell cut. A personal vault is one cell holding thousands
of notes; a note that becomes shared, or that must be reachable over a per-document MCP endpoint,
has to become its own `doc:<uuid>` cell while the vault keeps a derived, read-only row. Vellum's
ADR-18 takes that decision and blocks its stage 9 on a primitive it expects to live here, and its
DD-09 states that until the primitive exists a vault note cannot be shared at all.

Underneath it is a question this repo had not answered.
[ADR-19](ADR-19-the-cell-cut-is-a-choice.md) claims the cell cut is a choice. A cut that can be
chosen once and never changed is a weaker claim than that reads as, and nothing in the library
had ever moved a record across a cut.

The constraint is fixed and not negotiable. There is no locking primitive that spans cells and
there cannot be: separate files, separate connections, and WAL loses cross-database atomicity even
with `ATTACH` ([ADR-05](ADR-05-refuse-cross-cell-transactions.md)). SQLite has no row-level
locking either — the granularity is the database. So a handoff cannot be atomic, and the only
available shape is idempotent, resumable, and with exactly one place that answers "has this
happened".

## Options considered

### Option A — the object store as arbiter

The source writes a handoff object keyed by its own txid, in the namespace every owner past and
present shares ([ADR-08](ADR-08-fence-by-shared-txid.md)); the target adopts from it. Reuses
fencing already trusted.

Buys: an answer to "has this happened" that survives the source losing its local file, which is
the one thing the taken option does not have (see *Consequences*).

Costs: the key is the problem. A txid counts *shipments*, so two promotions of the same record
between two periodic snapshots would address the same object, and a retry across a snapshot would
address a different one — measured, and the same class of error as
[ADR-08](ADR-08-fence-by-shared-txid.md)'s generation counter that restarted at 1. Keying by
something else means a second encoder for a second kind of key, and
[ADR-07](ADR-07-opaque-cell-keys.md) exists because a non-injective encoder mapped `"a:b"` and
`"a_b"` onto one file. And the object is then a third place that can disagree with two cells,
in a design whose whole reason for a marker was that there be exactly one. Lost, but it is the
option to revisit first if the restore hole below ever bites.

### Option B — branch-shaped: snapshot a subset at a txid, then fast-forward

Vellum's ADR-18 assumes this generalises from the `branch` demo. It does not, and both halves
fail independently.

The snapshot half: `AshCell.Branch.fork/3` copies a whole *object* — the database file the
replicator PUT at a txid — under a new cell key. There is no such thing as a subset of it without
opening it and running a query, and which rows constitute "the record" is a transitive closure
across the application's own tables. That is domain knowledge the library does not have and
[ADR-07](ADR-07-opaque-cell-keys.md) deliberately keeps it from having: a resolver sees the tenant
and not the query.

The fast-forward half is worse, because it is not merely absent but inverted. Fast-forward
succeeds only when the *origin* has not been written to since the branch point. A vault is serving
continuously, so every promotion would be refused — and the refusal would be correct by the rule
and useless by intent. There is also nothing to fast-forward *to*: the target of a handoff is a
new, empty cell, not an origin with a history.

Costs: none, because there is nothing here to take. Named at length because it is the belief that
has to be corrected upstream.

### Option C — a dedicated `AshCell.Handoff`, two-phase through the store

A library module driving the sequence, with the application supplying callbacks for the read and
the write.

Buys: one place where the ordering is right, so a second consumer cannot get it wrong.

Costs: the library cannot perform step 2 at all — extracting and re-inserting the record is
entirely the application's schema — so the module degenerates into a state machine whose
interesting parts are all callbacks, and the application still writes them. It is a cross-cell
orchestrator, which [ADR-05](ADR-05-refuse-cross-cell-transactions.md) refused for reasons that
have not changed. It has exactly one consumer. And "two-phase" is the shape this ADR is correcting.
Lost on the first cost alone: a coordinator that cannot perform the step that matters is a
coordinator in name.

### Option D — resolve by probing for a deterministically-named cell

Skip the pointer: name the target `doc:<record_id>`, and on every read check whether that cell
exists — if it does, it is the record; if not, fall back to the source.

Buys: no pointer to keep, and no write to the source on the read path.

Costs: it is wrong, and not merely expensive. Between phase 2 and phase 3 the target **exists**
and the source is **still authoritative** — that window is what makes an interrupted handoff
recoverable rather than lossy, and this rule reads the wrong cell for the whole of it. It cannot
be fixed by reordering the probe, because existence is not a state the protocol controls, whereas
the pointer is.

Three further costs, each already recorded elsewhere in this repo. "Exists" has three different
answers — a local file on *this* node, a snapshot under the key in the bucket, a resident process
— and only `AshCell.Branch`'s private `refuse_if_used/2` asks, checking two of them, because a
cell can be durable and not yet resident here. A store that cannot be listed must fail the
question rather than answer "no", or a LIST timeout routes the read back to a source that no
longer owns the record; that is `AshCell.Replicator.latest_txid/2`'s rule
([ADR-08](ADR-08-fence-by-shared-txid.md)) on the read path. And a probe that falls through to
`AshCell.Manager.ensure_started/1` conjures a cell, which the `vcs` demo's end-to-end script
exists in part to refuse.

Lost, and it is the reason there is deliberately no `AshCell.exists?/1`. Should one ever be added
it must be named for which of the three questions it answers and must propagate a listing error —
and it still must not be used to route a read.

### Option E — decline, publish the ordering, and prove it with a probe *(taken)*

The library ships nothing new. This ADR states the three-phase protocol and the key, and
`test/handoff_probe_test.exs` drives it by hand against two real cells and MinIO — including the
two failures that decided the key.

Buys: no new surface, no second encoder, no cross-cell code path, and the correction that actually
matters — the ordering and the key — is delivered where a reader of this repo and a reader of
Vellum will both find it. Follows this repo's own rule about preferring a probe over
infrastructure for an answer nobody has yet.

Costs: Vellum writes the driver, and a second consumer would write it again. If a third arrives,
this ADR should be revisited with Option C's shape and the probe as its specification.

## Decision and why

Option E, and the argument that settled it is Option C's first cost rather than Option E's
elegance. Every part of a handoff that the library could own is bookkeeping the application
already has — Vellum's DD-09 data model has the `promoted_to` column on `notes` before any of this
was designed — and the one part that is genuinely hard, moving the rows, is the part the library
structurally cannot do. What was actually missing was not a module. It was the ordering, and the
knowledge that the two obvious keys are wrong.

The measurements that picked the key rather than argued it:

- **A txid identifies a shipment, not a record's state.** Two consecutive ships with no write in
  between returned txid N and N+1 over an unchanged row. So `source_txid` in an idempotency key
  varies for reasons unrelated to the record, in both directions.
- **A source can forget its own reservation.** A source restored from a snapshot taken *before*
  the reserve commit comes back with the record `owned` — the reservation is gone and a retry
  mints a fresh attempt id. Under a record-keyed import the target absorbs it and holds one row;
  under an attempt-keyed import the target holds **two**. Measured, both in the same test.

The second is why the key must be the record's identity. It is also the strongest argument for
Option A that remains, and it is left open below rather than claimed handled.

The three-commit ordering is reasoned rather than measured: the lost-edit window in the two-commit
version follows from the source being writable, and the probe demonstrates the reserved source
refusing a write rather than measuring an interleaving that loses one.

## Consequences

- **What it rules out.** Any library-level record movement, and with it any prospect of AshCell
  offering "change the cut" as an operation. Changing a cut remains an application-level migration
  of records, performed under this ordering, one record at a time.
- **What it makes worse.** [ADR-19](ADR-19-the-cell-cut-is-a-choice.md)'s claim is narrower than
  it reads. The cut is a choice at design time and changing it later is real work the library does
  not help with. ADR-19 is not reversed — it is qualified, and this ADR is the qualification.
- **What stays open.**
  - **A restore can strand a record.** If the source is fenced between reserve and release, it is
    quarantined by [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md) and an operator restores
    it from its last good snapshot — which may predate the reserve. The record then reads as
    `owned` in a source that never released it, while the target already holds it. The
    record-keyed import means the retry is absorbed rather than duplicated, which is what makes
    this recoverable rather than corrupting, but the *window of two writable copies* is real and
    only Option A closes it. Measured, and the reason Option A is named as the first revisit.
  - **Reads of a promoted record are cross-cell**, so `load`-only and non-atomic, exactly as
    Vellum's DD-09 already concedes. Following the pointer is two binds, in two processes' worth
    of ambient state, with no transaction across them; the second bind can find a cell that has
    moved on since the first was read.
  - **Demotion** — moving a record back — is a second handoff under the same ordering, and is not
    designed here.
  - Whether a third consumer justifies Option C.
- **What now depends on it.** Vellum's ADR-18 and DD-09 stage 9; `test/handoff_probe_test.exs`;
  ADR-19's scope.

## Evidence

- **Measured**, `test/handoff_probe_test.exs`, `"the source's txid advances without the record
  changing"` — one note written, `AshCell.Replicator.ship/2` twice with no write between; txids N
  and N+1, body unchanged. This is what disqualifies `source_txid` from an idempotency key.
- **Measured**, `test/handoff_probe_test.exs`, `"absorbs a repeat under a new attempt id, where an
  attempt-keyed one duplicates"` — the load-bearing one. Same record, two attempt ids, both
  imports run twice: `imports` holds 1 row, `imports_by_attempt` holds 2.
- **Measured**, `test/handoff_probe_test.exs`, `"a source restored from a snapshot older than the
  reservation forgets it"` — ship at txid N, reserve, `AshCell.Replicator.restore/3` to N; the
  record reads `owned`. This is what makes the previous test's premise a real state rather than a
  hypothetical, and it is the open hole in *Consequences*.
- **Measured**, `test/handoff_probe_test.exs`, `"leaves the source authoritative, readable and
  retryable"` — interrupted after the transfer: the source's row is still readable, refuses a
  write guarded on `owned` (0 rows affected), and a repeated release is a no-op.
- **Read from source**, `lib/ash_cell/branch.ex:70` at this repo's `main`: `fork/3` takes
  `AshCell.Replicator.snapshot_key(origin, txid)` and writes the returned bytes as a whole
  database file. There is no subset path and no place one could be inserted without a query.
- **Read from source**, `lib/ash_cell/branch.ex:184`: `require_fast_forward/2` compares the
  origin's current digest to the one recorded at fork. A continuously-served origin never matches,
  which is [ADR-23](ADR-23-merge-by-fast-forward-or-refuse.md) working as designed and useless for
  a handoff.
- **Read from source**, `lib/ash_cell/replicator.ex` moduledoc and
  [ADR-23](ADR-23-merge-by-fast-forward-or-refuse.md): the txid counts shipments and the snapshot
  policy ships on a schedule. The probe measures it; this is where it is already written down.
- **Read, not measured.** SQLite has no row-level locking; the granularity is the database. There
  is nothing to probe for. The `reserved` state above is committed state in a single-writer
  database, not a lock, and the distinction is what makes it available at all.
- **Neither measured nor read.** The three-commit ordering's advantage over two commits is
  reasoned from the source being writable in the two-commit window; no interleaving that loses an
  edit was constructed. Prior art (Orleans, Spanner, Durable Objects) is cited from Vellum's
  ADR-18 and was not re-read for this.
- **Not verified.** The cost of a handoff at Vellum's scale — thousands of notes, a promotion
  touching a note's whole update log — is unknown, and belongs to DD-09's owed measurements rather
  than here.

## Notes

No design doc accompanies this ADR. `docs/design/` holds documents for work that gets built, and
the decision here is that none is. The protocol above and `test/handoff_probe_test.exs` are the
specification; if Option C is ever taken, that probe is what it has to satisfy, and a DD-14 gets
written then.

Vellum's ADR-18 needs one correction, in its Evidence section: "the `branch` demo's
snapshot/cut/fast-forward machinery … *generalises* to a subset handoff is an argument, not a
demonstration" is not merely undemonstrated, it is false, for the two independent reasons in
Option B. Its Decision and why paragraph resting the affordability of Option C on that reuse needs
the same correction. The rest of ADR-18 stands: the handoff shape it argues for is the one taken
here, and its Option D was rejected for the right reason.
