# DD-07 — Durable timers

**Status:** draft
**Date:** 2026-08-24
**Decisions:** [ADR-18](../decisions/ADR-18-tenant-in-job-args.md), [ADR-01](../decisions/ADR-01-bind-tenants-per-process.md), [ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md), [ADR-21](../decisions/ADR-21-close-does-not-await-the-connection.md)
**Lands in:** `lib/ash_cell/timers.ex` (new), `lib/ash_cell/cell.ex`, `lib/ash_cell/manager.ex`

## What this is

A `(fire_at, payload)` table inside each cell, plus the cell process arming a single
`Process.send_after/3` for its own next-due row. When the timer fires the cell runs the due
callbacks *itself* — already the owner, already bound — and re-arms. A cell that was evicted or
moved replays whatever came due while it was gone, on its next activation.

Per-tenant scheduling with no fleet-wide scheduler, no polling table, and no routing step.

## What this proves

- A scheduled callback runs **inside the cell's owner**, so it needs no tenant argument and no
  binding hand-off: the boundary problem that [ADR-18](../decisions/ADR-18-tenant-in-job-args.md)
  works around does not arise, because there is no boundary to cross.
- Scheduling is transactional with the work that scheduled it: "write this row and wake me in an
  hour" is one commit, so a timer for a write that rolled back does not exist.
- A timer survives eviction, node loss, and cell migration. Fire time is *at or after* `fire_at`,
  never before, and lateness is bounded by activation time rather than unbounded.
- Fleet cost of N cells with timers is O(active cells), not O(N): a cold cell with a future timer
  costs nothing until something wakes it — and the design states plainly which timers therefore
  do *not* fire on time.
- No thundering herd on a shared deadline: each cell reads only its own rows, so 10 000 cells with
  a midnight timer contend on nothing (they do contend for activation slots, which is measured).

## Why it needs a cell

A timer needs three things: durable state, exclusive execution, and a live process. A shared
`jobs` table gives the first, buys the second with `SELECT … FOR UPDATE SKIP LOCKED` — which
SQLite has no equivalent of, and AshSqlite has no locks at all — and gets the third from a worker
pool that must then be told which tenant to bind. A cell has all three natively: the file is
durable, the fence makes execution exclusive, and the GenServer is the process. The BEAM's
`send_after` is the missing 5%.

The interesting consequence is negative: this only works because cells are *activated*. It cannot
schedule work for a tenant nobody ever touches.

## Non-goals

- **Not a general job queue.** No retries with backoff across a fleet, no dead-letter queue, no
  cross-tenant fairness or priority. AshOban remains the right tool for fleet-wide work, and this
  does not replace it.
- **Not a replacement for [ADR-18](../decisions/ADR-18-tenant-in-job-args.md).** Work that must
  run whether or not a cell is warm still goes through Oban with the tenant in its args. This
  handles the case where the work belongs *to* the cell.
- **Not sub-second scheduling.** Resolution is coarse (target: 1 s) and the doc will state the
  measured floor rather than a promise.
- **Not guaranteed to fire while cold.** See *Where it stops*; this is the central limitation and
  it is not hidden.
- **Not distributed cron.** No leader election, no "exactly one node fires this" beyond what the
  lease already guarantees for the cell.
- **Not a way to keep cells warm.** A timer must never be a reason to pin a cell in memory; that
  would invert the eviction design in [DD-01](DD-01-cell-runtime.md).

## Data model

One table per cell, `ash_cell_timers`: `id`, `fire_at` (utc datetime, indexed), `kind` (atom-ish
string naming the handler), `payload` (map), `attempts`, `last_error`, `inserted_at`. Plus
`unique_key` (nullable, unique) so "reschedule this tenant's digest" is an upsert rather than a
duplicate.

The cell holds one piece of state: the `fire_at` and reference of the single armed BEAM timer.
Arming *one* timer for the earliest row, rather than one per row, keeps a cell with 10 000 pending
timers cheap and makes re-arming after each fire the only invariant to get right.

Handlers are modules implementing `AshCell.Timers.Handler` — `handle_fire(payload, ctx)` returning
`:ok`, `{:retry, in: duration}`, or `{:error, reason}`. A handler runs in the cell process, so a
handler that blocks blocks the cell; the doc must say this in the callback's own `@doc`, not only
here.

## Trade-offs

- **Fire in the cell process vs a task supervised beside it.** In-process gives the binding and
  the exclusivity for free and makes a slow handler a cell-wide stall. A task needs an explicit
  binding ([ADR-01](../decisions/ADR-01-bind-tenants-per-process.md): the binding is ambient and
  does not survive `Task.async`) and reintroduces the concurrency the cell exists to remove.
  Chosen: in-process, with a configurable handler timeout that kills the handler rather than the
  cell, and a documented "do not do slow work here — enqueue it".
- **Replay-on-activation vs a sweeper that activates cells with due timers.** Replay alone means
  a cold tenant's timer is late by however long until someone touches it. A sweeper makes timers
  punctual and reintroduces a fleet-wide scan plus a thundering herd. Chosen: replay in stage 1,
  and an **optional** sweeper in stage 4 that the operator turns on knowingly, with the herd cost
  measured before it ships.
- **One armed timer vs one per row.** One per row is simpler and unbounded. Chosen: one.
- **Retry state in the row vs in the handler.** In the row, so a retry survives eviction.

## Measurements this must produce

Median of 5, and cold/warm distinguished throughout:

- **Fire-time accuracy** on a warm cell: distribution of `fired_at - fire_at` at 1 / 100 / 10 000
  pending timers in a cell. The claim is "at or after, bounded"; this gives the bound.
- **Replay latency on activation** for a cell with 1 / 100 / 1 000 overdue timers, since this is
  added directly to the first request that touches a cold cell — a **cliff**: state the overdue
  count at which activation crosses 500 ms.
- **Arming overhead per append**: the cost added to a write that schedules a timer versus one that
  does not.
- **Herd cost**, if the optional sweeper ships: wall-clock and p99 activation latency for 1 000
  cells all due at the same instant, with and without jitter.
- **Cost of a cold fleet**: CPU and memory for 10 000 cells with pending timers, none activated,
  to substantiate O(active) rather than O(N).

## Staging

1. **Table, `schedule/3`, `cancel/1`, replay on activation.** No BEAM timer yet — timers fire only
   on activation. Checkable: an overdue timer fires on the next touch; a cancelled one does not;
   scheduling inside a rolled-back transaction leaves nothing.
2. **Arming and re-arming** the single `send_after`. Checkable: fire-time accuracy on a warm cell;
   re-arm correctness when a *nearer* timer is inserted after arming (the easiest bug here).
3. **Handler contract**, retries, `unique_key` upsert, handler timeout. Checkable: a handler that
   raises retries with its attempt count persisted across an eviction; a handler that hangs is
   killed and the cell survives.
4. **Eviction and migration interaction.** Checkable: a cell evicted with an armed timer fires on
   reactivation and not twice; a cell drained to another node does not double-fire (the lease is
   the argument, and the test must show it).
5. **Optional sweeper**, behind config, with the herd measurement as its gate.
6. **A demo use**: `shroud` session expiry, or `rollout` a scheduled channel promotion.

## Where it stops

- **A cold cell's timer does not fire until the cell is activated.** For many uses (expire this
  session, send this digest on next login) that is fine. For "bill this customer at midnight" it
  is wrong, and the answer is Oban, not this. Nothing in the API stops the mistake.
- Fire-once is guaranteed by the lease, not by the timer: if fencing is wrong, a timer can fire
  twice. It inherits [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md)'s guarantees and no more.
- A handler's *side effects* are at-least-once. Making the effect and the row one commit is
  [DD-08](DD-08-durable-execution.md).
- No visibility across the fleet: "what is scheduled for every tenant" requires touching every
  cell. There is no global index and this doc does not add one.
- Clock skew across nodes is not handled. `fire_at` is wall clock, and a cell that migrates to a
  node with a skewed clock fires accordingly.
- Durability of a scheduled timer is [ADR-20](../decisions/ADR-20-choose-a-durability-level.md)'s
  open question.

## Open risks

- **Re-arm correctness is the whole structure.** Every path that inserts, cancels, or completes a
  timer must reconsider the armed one. This wants a property test over random interleavings, not
  example tests, and that test is part of stage 2 rather than a follow-up.
- **A handler running in the cell process can starve queries.** The timeout bounds it; whether the
  default timeout is right is unknown until something real uses it.
- Interaction with drain: a timer firing while the cell is draining. Should be refused and re-armed
  by the new owner; the refusal is not designed yet, and [ADR-21](../decisions/ADR-21-close-does-not-await-the-connection.md)
  means the connection may already be going away underneath it.
