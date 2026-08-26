# ledger — design

**Status:** draft
**Date:** 2026-08-25
**Decisions:** [ADR-04](../../../docs/decisions/ADR-04-transactions-behind-an-opt-in-flag.md),
[ADR-05](../../../docs/decisions/ADR-05-refuse-cross-cell-transactions.md),
[ADR-19](../../../docs/decisions/ADR-19-the-cell-cut-is-a-choice.md),
[ADR-20](../../../docs/decisions/ADR-20-choose-a-durability-level.md),
[ADR-16](../../../docs/decisions/ADR-16-isolation-is-blast-radius.md)
**Design doc it rests on:** [DD-06](../../../docs/design/DD-06-append-log-and-compaction.md), with
[DD-05](../../../docs/design/DD-05-time-travel-and-forks.md) for the temporal half
**Lands in:** `lib/ledger/{books,accounts,posting,replay}.ex`, `lib/ledger_web/live/book_live.ex`,
and in the library `lib/ash_cell/log.ex`

## What this is

Double-entry bookkeeping as an event-sourced system on cells. **One cell per book** — a set of
accounts that balance against each other — with one [DD-06](../../../docs/design/DD-06-append-log-and-compaction.md)
log scoped per account, and each account's checkpoint row holding its balance as a typed column
rather than a blob.

A transfer between two accounts *in the same book* is one transaction: two events appended, two
checkpoints advanced, the book's invariant checked, commit. A transfer between two books cannot be,
and the demo shows that rather than hiding it.

## What this proves

- **A cross-aggregate invariant enforced inside the append transaction.** Debits equal credits
  across every account in the book, checked before commit. A distributed event store cannot do this
  — it can only detect the violation afterwards and compensate. This is the demo's central claim.
- **`expected_version` rejects a stale decision, and the cell is why the check is enough.** One
  writer and `BEGIN IMMEDIATE` remove the *race*; the version check catches the *stale command* —
  a handler that read the account at version 7 and decided while version 8 landed. Shown with two
  browser tabs posting against one account, one refused.
- **The checkpoint row is the read model.** `accounts.balance` is an indexed column, so a trial
  balance is one query rather than a fold over every account — and it is provably equal to folding
  the log, checked by property test.
- **The freshness dial is real and measurable.** `compact_when entries: N` moves the read model
  between exact (`N = 1`, compaction in the append transaction) and cheap (`N = 500`, a trial
  balance stale by up to the tail). Both ends are measured, and the demo's UI shows the tail length
  so the staleness is visible rather than described.
- **Replay is bounded and rehearsable.** Rebuilding one book's balances touches one file; doing it
  in a [DD-05](../../../docs/design/DD-05-time-travel-and-forks.md) branch first, diffing against
  live, then cutting over, makes a projection rebuild a reversible operation.
- **The balance as of a past instant** is a real query, not a party trick: for a ledger it is the
  audit requirement.
- **The wall, shown.** A cross-book transfer is refused as one transaction and implemented as a
  two-phase saga, with the intermediate state — money committed out of one book and not yet into
  the other — visible in the UI.

## Why it needs a cell

The invariant is the argument. "Every posting balances, and the book's accounts sum to zero" is a
constraint over many aggregates that must hold at every commit. Event-sourced systems normally give
this up: aggregates are the transaction boundary, so cross-aggregate invariants become sagas and
eventual repair. A cell restores it for everything inside one file, because one file is one
transaction.

The second reason is the version check. Optimistic concurrency in a distributed event store needs a
conditional append the store has to implement (EventStoreDB's expected version, a DynamoDB
conditional put). Here it is a comparison inside a transaction held by the only writer.

**Where the cell is cut, and why not the obvious cut.** Per *account* is the obvious choice and it
is wrong: a transfer touches two accounts, and a transaction cannot span two cells
([ADR-05](../../../docs/decisions/ADR-05-refuse-cross-cell-transactions.md)), so every posting
would be a saga and the demo would prove the opposite of its claim. Cutting per **book** puts the
wall at the boundary where an accountant already expects one — you reconcile between books, you do
not reconcile within one.

## Non-goals

- **Not a general ledger product.** No currencies beyond a single minor-unit integer, no fiscal
  periods, no chart-of-accounts hierarchy, no reporting beyond a trial balance.
- **Not a CQRS framework.** There is no command bus, no separate read database, no projection
  daemon. The point is that on cells you need none of those; adding them would obscure it.
- **Not a Commanded comparison.** Commanded on Postgres gives a global event stream and higher
  per-aggregate throughput. This demo gives per-tenant isolation and atomic read models. Different
  trade, and the README says so rather than implying a benchmark.
- **Not cross-book atomicity.** Refused, demonstrated, and left refused.
- **Not a claim about durability** until [ADR-20](../../../docs/decisions/ADR-20-choose-a-durability-level.md)
  closes. See *Where it stops*.
- **Not float money.** Integer minor units only, and the property tests assert no arithmetic path
  produces a non-integer.

## Data model

Per book cell:

- **`accounts`** — the checkpoint rows, one per account. `id` (the log scope), `name`, `kind`
  (`asset | liability | equity | revenue | expense`), `balance` (integer minor units), `status`,
  `through_seq`, `updated_at`. This *is* the snapshot table of
  [DD-06](../../../docs/design/DD-06-append-log-and-compaction.md), with typed columns instead of a
  `state` blob — which is what makes a trial balance an ordinary query.
- **`entries`** — the event log, `scope` = account id, `seq` = that account's version, plus
  `posting_id`, `amount`, `kind`, `at`. **`truncate?: false`**: unlike `collab_editor`, compaction
  advances `through_seq` and never deletes, because in an event-sourced ledger the events *are* the
  record. Storage grows with history; read cost does not, because a read only touches
  `seq > through_seq`.
- **`postings`** — the double-entry envelope: one row per balanced posting, referenced by the two
  or more entries it produced. Exists so "show me the transaction" does not mean correlating two
  event rows by timestamp.
- **`commands`** — `command_id` primary key, for idempotent submission. Written in the same
  transaction as the events, so a retried command is a no-op rather than a double posting.

Nothing is denormalised across a data-layer boundary; the whole model is in the cell. The book's
catalogue (which books exist, who may see them) is a shared table on its own repo module
([ADR-06](../../../docs/decisions/ADR-06-own-repo-for-shared-tables.md)).

## Trade-offs

- **Per book vs per account**, argued above. The cost of per-book is that a busy book serialises
  every posting on one writer; the measurement below is what says whether that matters.
- **Typed checkpoint columns vs a state blob.** Columns make the read model queryable and tie the
  schema to the fold, so changing what an account's state contains is a migration. A blob is
  flexible and unqueryable. Chosen: columns, because the queryability *is* the CQRS half of the
  demo.
- **Never truncating vs truncating with object-store history.** Never truncating keeps replay-from-
  zero local and grows the file forever. Truncating would make the file small and put history in
  snapshots ([ADR-12](../../../docs/decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)), where
  a lifecycle rule could silently delete an audit record. Chosen: never truncate, and name the file
  growth as a cost rather than solving it.
- **Compaction inline (`entries: 1`) vs lazy.** Both ship; the demo exposes the setting and
  measures both, because the whole point is that this is one dial rather than two architectures.

## Measurements this must produce

Warm cell, median of 5, integer amounts, single node:

- **Postings/sec** at `entries: 1` (inline compaction) and `entries: 500` (lazy), single-threaded
  and at 8/32/64 concurrent submitters against one book. The ratio between the two settings is the
  price of an exact read model, and it is the number this demo owes.
- **Trial-balance latency** at 10 / 1 000 / 10 000 accounts, with an empty tail and with a tail of
  500 per account — the second is what staleness-vs-fold actually costs when you insist on exact.
- **Read cost as history grows**: `balance/1` at 10³, 10⁶ and 10⁷ total events with `through_seq`
  current, to substantiate that read cost is flat in history. A **cliff** would falsify the design;
  if one appears, state the event count.
- **File growth** per million events, since never-truncating is the chosen cost.
- **Replay from zero** for a book at 10⁶ events, and the same replay run inside a branch while the
  live book keeps serving — the second is the number that says whether rehearsed rebuild is
  practical.
- **Version-conflict rate** under N concurrent submitters against one account, to show the check
  fires rather than being theoretically present.
- **Durability**: whatever [ADR-20](../../../docs/decisions/ADR-20-choose-a-durability-level.md)
  settles on, measured here at `:normal` and `:full`, because a ledger is the workload where the
  fsync cost is most likely to be worth paying and least likely to be affordable.

## Staging

1. **Book cell, accounts, and a single-account append** with `expected_version`. Checkable: a
   stale version is refused; `balance/1` equals the fold.
2. **Postings — the two-sided write** with the balance invariant checked in-transaction.
   Checkable: an unbalanced posting is refused and leaves nothing behind; concurrent postings that
   would jointly unbalance the book cannot both commit.
3. **Checkpointing with `truncate?: false`**, and the `entries: N` dial. Checkable: the property
   `checkpoint ⊕ tail == fold(all events)` at every N, over generated histories.
4. **Idempotent commands.** Checkable: the same `command_id` submitted twice posts once, including
   across a cell eviction.
5. **Trial balance and the UI**, showing tail length and staleness explicitly.
6. **Temporal queries** on [DD-05](../../../docs/design/DD-05-time-travel-and-forks.md), and
   rebuild-in-a-branch-then-cut-over.
7. **The cross-book saga**, with the intermediate state visible.
8. **Measurements**, and the README's *where it stops* written from them rather than in advance.

## Where it stops

- **Durability is whatever [ADR-20](../../../docs/decisions/ADR-20-choose-a-durability-level.md)
  says, and today that is undecided.** Under `synchronous: :normal` an acknowledged posting can be
  lost on power loss — and for a ledger that is not stale data, it is a posting that never happened
  with balances already derived from it. Until ADR-20 closes, this demo must not claim durability,
  and its README must say so in its first paragraph.
- **No cross-book atomicity.** The saga leaves an observable intermediate state. That is shown, not
  fixed.
- **No global view.** "Every book's trial balance" is a fan-out over cells with no shared index —
  the same cost `collab_editor` shows for listing documents.
- **One writer per book.** A book with high posting throughput serialises, and the measurement says
  where that bites.
- **The read model is only as fresh as the last compaction** unless `entries: 1`, and any query
  reading `accounts.balance` without overlaying the tail is reading a memo. The UI makes this
  visible; an API consumer would have to be told.
- **No audit of who did what** beyond `command_id` — authorization and actor identity are the
  application's, and this demo does not model them.
- **Isolation here is blast radius, not confidentiality**
  ([ADR-16](../../../docs/decisions/ADR-16-isolation-is-blast-radius.md)). The node holds the key.

## Open risks

- **The demo's headline claim depends on an unclosed ADR.** If ADR-20 lands on per-cell policy,
  this demo's cells take `:full` and the README states the measured cost; if `:full` proves
  unaffordable, the honest outcome is that the demo documents a durability gap rather than being
  quietly shipped without one.
- **Never truncating makes the file grow without bound.** Fine at demo scale, a real operational
  question at ten years of postings, and nothing here solves it. Cutting the cell per book *per
  year* (`book:acme:2026`) is the obvious answer and would make the demo's cut argument more
  complicated; it is deliberately not taken here.
- **Typed checkpoint columns couple the schema to the fold**, so evolving an account's state is a
  migration across every cell — the same fleet-wide migration problem CLAUDE.md already lists as
  unsolved.
- Whether `entries: 1` is fast enough to be the default. If it is, the freshness dial is a much
  less interesting finding than this doc assumes, and the doc should be cut back to say so.
