# DD-08 — Durable execution: tenanted workflows

**Status:** draft
**Date:** 2026-08-24
**Decisions:** [ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md), [ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md), [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md), [ADR-20](../decisions/ADR-20-choose-a-durability-level.md)
**Lands in:** `lib/ash_cell/workflow.ex` (new), `lib/ash_cell/outbox.ex` (new), on top of [DD-06](DD-06-append-log-and-compaction.md) and [DD-07](DD-07-durable-timers.md)

## What this is

A workflow engine whose unit of isolation is a cell. A workflow instance is a row; its history is
a [DD-06](DD-06-append-log-and-compaction.md) log; its waits are
[DD-07](DD-07-durable-timers.md) timers; its external calls go through an outbox. The state
transition and the record of the effect that caused it commit in **one** `BEGIN IMMEDIATE`
transaction, and the fence guarantees no second worker is advancing the same instance.

The comparison worth being precise about: Temporal spends a database cluster, a task-queue service,
and a sharding layer to guarantee single-writer-per-workflow-id. Here that guarantee is the
primitive, so what is left to build is the history, the replay, and the outbox.

## What this proves

- **Exactly-once state, at-least-once effects,** and the difference is visible in the API rather
  than buried. Advancing a workflow past a step is atomic with recording that the step ran; the
  outbound HTTP call is not, and the design says so at the call site.
- A workflow interrupted anywhere — process kill, node loss, cell taken mid-transaction — resumes
  from its last committed step and never from a half-applied one. Established for transactions
  generally by [ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md); this shows it
  for a multi-step process.
- Two nodes both believing they own a tenant cannot both advance a workflow: the loser finds out
  at its next durability write, before acknowledging
  ([ADR-08](../decisions/ADR-08-fence-by-shared-txid.md)).
- Replay is deterministic: re-running a workflow's history against the same definition produces
  the same step sequence, checked by property test over recorded histories.
- No task-queue infrastructure. A run of N workflow instances across M tenants needs a bucket, a
  SQLite file per tenant, and the BEAM.
- The **unreferenced-body problem is closed for the cell's own state.** The intent row that
  precedes an object-store upload *is* the sweep list, so an orphan is discoverable rather than
  invisible — which is the gap s3collections names and cannot close.

## Why it needs a cell

The whole engine is the single-writer guarantee. Without it, "advance this workflow" is a
distributed lease problem, and every serious implementation solves it by sharding workflow ids
onto owners — which is what a cell key *is*. The transactional half needs the state and the
history in one database, which they are.

The cut is per whatever the workflow is about ([ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md)):
per customer for onboarding, per document for a publishing pipeline, per repository for CI. That a
workflow cannot span cells is the cost, and it is priced in *Non-goals* rather than worked around.

## Non-goals

- **Not distributed workflows.** A workflow instance lives in exactly one cell. Fan-out to another
  tenant is a message with its own workflow there, not a child activity — because a transaction
  cannot span two cells ([ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md)) and
  faking it with a saga is a different design.
- **Not Temporal-compatible.** No Temporal SDK, protocol, or semantics beyond the ideas. No
  signals-with-start, no continue-as-new, no child workflows in v1.
- **Not exactly-once side effects.** Impossible without the remote participating. The outbox gives
  at-least-once with an idempotency key the caller supplies, and the docs will not soften that.
- **Not a general-purpose orchestrator.** No visual designer, no cross-tenant scheduling, no
  fleet-wide "show me all running workflows" (see *Where it stops*).
- **Not a replacement for Ash's `Reactor`.** Reactor composes steps in one request with
  compensation; this survives a node dying. Where they overlap, prefer Reactor.
- **Not shippable while [ADR-20](../decisions/ADR-20-choose-a-durability-level.md) is open.** A
  durable-execution engine makes a durability promise, and that promise is currently unproven.
  This is a gate, not a caveat.

## Threat model

| Adversary | What they get | What stops them |
|---|---|---|
| A fenced node still advancing a workflow | Two workers running the same step | The shared-txid namespace: the loser's next durability write is refused before it acknowledges ([ADR-08](../decisions/ADR-08-fence-by-shared-txid.md)). Between commits, both may *attempt* effects — hence at-least-once. |
| A crash between outbox commit and the remote call | An effect that never happened, recorded as pending | Recovery scans pending intents on activation and retries. Discoverable by construction. |
| A crash between the remote call and marking it done | The effect happens twice | The caller's idempotency key, or nothing. This row is the honest one. |
| A workflow definition changed mid-flight | Replay diverging from recorded history | `definition_version` on the instance; a changed definition refuses to replay rather than guessing. Migration of in-flight instances is not solved. |
| Untrusted payload driving a step | Arbitrary handler input | The application's; the engine does not validate payloads beyond the Ash action that accepted them. |

## Data model

Per cell, three tables plus one log:

- **`workflow_instances`**: `id`, `definition`, `definition_version`, `state` (map), `status`
  (`running | waiting | done | failed`), `current_step`, `inserted_at`, `updated_at`.
- **`workflow_history`** — a [DD-06](DD-06-append-log-and-compaction.md) log per instance, folded
  by the definition's reducer. History is what makes replay possible and what compaction bounds;
  a long-running instance keeps a snapshot plus a tail, not a year of steps.
- **`outbox_intents`**: `id`, `instance_id`, `step`, `kind`, `payload`, `idempotency_key`,
  `status` (`pending | sent | failed`), `attempts`, `last_error`. The intent commits *with* the
  state transition; the send happens after; the mark-sent is its own commit.
- **Waits** are [DD-07](DD-07-durable-timers.md) rows with `kind: :workflow_wake` and the
  instance id in the payload, so a sleep is a timer and a timeout is a timer.

The ordering is the whole safety argument and is worth stating as one line: **commit the intent,
then perform, then commit the result.** A crash before the perform leaves a pending intent
(retried); a crash after leaves a pending intent whose effect already happened (retried, hence the
idempotency key). There is no window in which an effect happened and nothing records that it was
supposed to.

## Trade-offs

- **Replay-from-history (Temporal's model) vs continuation-passing (a step returns the next step).**
  Replay needs deterministic definitions and gives free "resume anywhere"; continuations need no
  determinism and cannot recover a step that was mid-flight. Chosen: replay, with
  `definition_version` refusing on drift, because the determinism constraint is the one Temporal
  found worth paying.
- **Effects in the cell process vs a task.** Same trade-off as [DD-07](DD-07-durable-timers.md) and
  resolved differently: an outbound HTTP call is slow, so the *send* runs in a supervised task,
  which is safe precisely because the send is the non-transactional part. The commits stay in the
  cell. This is the one place the design deliberately leaves the cell process, and the reason is
  that the ambient binding it loses ([ADR-01](../decisions/ADR-01-bind-tenants-per-process.md)) is
  not needed for a network call.
- **Per-instance history log vs one log per cell.** Per-instance makes compaction and replay
  scoped; one log per cell makes ordering across instances meaningful and compaction impossible.
  Chosen: per instance.
- **Build on Oban instead.** Oban gives retries, backoff, and observability for free, and gives up
  the atomicity of state-plus-effect — an Oban job and a cell write are two transactions. Chosen:
  build here, and use Oban for the fleet-wide half where the atomicity does not matter.

## Measurements this must produce

Warm cell, median of 5:

- **Steps/sec** for a trivial 10-step workflow, single instance and 100 concurrent instances in one
  cell (they serialise on the writer — the number shows *how much*, and it is the headline
  trade-off against Temporal).
- **Recovery time** for a cell activating with 1 / 100 / 1 000 in-flight instances, replay
  included. A **cliff**: the instance count at which activation crosses 1 s.
- **History growth and compaction cost** for a 10 000-step workflow, before and after.
- **Outbox drain latency** p50/p99 from commit to send, warm and after a cold activation.
- **A fencing test, not a benchmark**: two nodes both advancing one instance, asserting the loser's
  effects stop at its first durability write and the state is single-valued.
- **Against Temporal, on one dimension only**: end-to-end latency for the same 10-step workflow.
  Not a general benchmark — a single honest number with the infrastructure difference stated.

## Staging

1. **Gate: close [ADR-20](../decisions/ADR-20-choose-a-durability-level.md).** Nothing else starts.
2. **`AshCell.Outbox` alone**, no workflows: commit-intent → perform → commit-result, with recovery
   on activation. Checkable: kill at each of the three points and assert the invariant (no effect
   without a record; every pending intent eventually sends). This stage is independently useful and
   should ship on its own.
3. **Instance + history + a linear step runner**, no waits. Checkable: a 5-step workflow resumes
   from step 3 after a kill; replay determinism property test.
4. **Waits and timeouts** on [DD-07](DD-07-durable-timers.md). Checkable: sleep survives eviction;
   a timeout fires once.
5. **`definition_version` and refusal on drift.** Checkable: an in-flight instance whose definition
   changed fails loudly rather than replaying wrong.
6. **Compaction of history** via [DD-06](DD-06-append-log-and-compaction.md), then measurements.
7. **A demo**: `console` per-tenant onboarding, or `vcs` a per-repository CI pipeline — chosen for
   which one has a real multi-step process, not for which is easier.

## Where it stops

- **One cell per workflow.** No cross-tenant orchestration, no child workflows in another cell.
- **Effects are at-least-once.** Every remote call needs an idempotency key and the engine cannot
  supply one.
- **No fleet-wide view.** "Which workflows are stuck" means touching every cell. No global index,
  no dashboard, and the absence is structural rather than unfinished.
- **In-flight definition migration is unsolved.** Changed definitions refuse; draining old
  instances before deploying a new definition is the operator's problem.
- Determinism of a definition is unenforced — a step that reads the clock or calls a network
  breaks replay and nothing detects it.
- Throughput per cell is one writer's throughput. A tenant needing 10 000 workflow steps/sec is
  the wrong shape for this and the measurement above should make that obvious.
- Cold instances do not advance, inheriting [DD-07](DD-07-durable-timers.md)'s central limitation.

## Open risks

- **[ADR-20](../decisions/ADR-20-choose-a-durability-level.md) is the gate and it is open.** With
  `synchronous: :normal`, a committed step can be lost on power loss, which for this feature is
  not a performance footnote but a broken promise. The simulator models the object store, not
  fsync ([ADR-11](../decisions/ADR-11-simulate-the-protocol-only.md)), so it will keep agreeing
  regardless — this needs a real power-loss or `dm-flakey`-style test.
- **Replay determinism is a constraint on user code that the library cannot check.** Mitigations
  (a linter, a recorded-history diff in CI) are speculative.
- **The outbox send leaves the cell process**, which is the one deliberate exception to
  "everything happens in the owner". Whether that exception stays contained is the thing to watch
  in review.
- Instance concurrency within a cell serialises on `pool_size: 1`; whether that is a wall or a
  non-issue is unknown until the steps/sec number exists.
