# ADR-20 — Choose SQLite's durability level (`synchronous`)

**Status:** proposed — still open, but with a plan that can close it
**Last changed:** 2026-08-31 — built all three fault-injection tiers; pinned `journal_mode`, which this ADR's framing depends on;
recorded that `synchronous` is already settable via repo config, and that `:normal`'s loss window
is the WAL rather than the last commit. Added the cost probe and its macOS numbers, which show
group commit amortising the fsync almost perfectly. The decision itself is still open: the Linux
numbers are still owed, and tier 3 has not yet had a green run.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-11](ADR-11-simulate-the-protocol-only.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md) · [ADR-13](ADR-13-pool-size-one-and-cache.md) · [ADR-19](ADR-19-the-cell-cut-is-a-choice.md) · `demos/ledger/docs/design.md`

## The decision

No decision has been made. This ADR records the open question, not a choice: exqlite defaults to
`synchronous: :normal`, and `cell.ex` does not override it. Whether to keep `:normal` or move to
`:full` is undecided.

## Context

In WAL mode, `synchronous: :normal` means a returned `COMMIT` is not necessarily fsynced, so recent
commits can vanish on power loss or a kernel panic. This directly undermines the DST invariant
`no_acknowledged_write_lost`: the simulator in [ADR-11](ADR-11-simulate-the-protocol-only.md) models
the object store, not fsync behaviour, so it will keep agreeing with itself regardless of which
`synchronous` level is set. This has been named the top open risk on the project — data could be
lost without anyone noticing.

## Options considered

### Option A — `synchronous: :normal` (current default, unexamined)

What it buys: whatever exqlite's default throughput is; nothing has been changed to get it. What it
costs: a returned `COMMIT` is not durable against power loss or a kernel panic in WAL mode. This is
the status quo, not a decision to keep it.

### Option B — `synchronous: :full` everywhere

What it buys: a returned `COMMIT` is fsynced, closing the gap with `no_acknowledged_write_lost`.
What it costs: unknown. No throughput measurement has been taken comparing it against `:normal`.
The cost is paid by every cell, including ones whose contents are a cache and whose loss window
nobody would care about.

### Option C — durability as a per-cell policy

`synchronous` is a first-class connection option — `:extra | :full | :normal | :off`,
defaulting to `:normal` (`deps/exqlite/lib/exqlite/connection.ex:115`) — and it is set per
connection, so per cell. AshCell never sets it today.

What it buys: a ledger cell takes `:full` and pays the fsync; a cache-shaped or
projection-rebuild cell stays `:normal`. The tradeoff becomes explicit at the declaration site
rather than global and invisible, which is the same argument
[ADR-19](ADR-19-the-cell-cut-is-a-choice.md) makes about the cut itself.

What it costs: two durability levels in one fleet means the answer to "is an acknowledged write
durable here?" is "it depends on the cell", and every claim in the docs has to be qualified by
which policy the cell runs under. It also makes the DST invariant `no_acknowledged_write_lost`
conditional, which is worse than either uniform answer.

## Decision and why

No decision has been made. This is stated plainly and deliberately: the choice between `:normal`
and `:full` needs a measured throughput comparison, not an assumption in either direction. Nothing
in the evidence establishes what that comparison would show. Until that measurement exists, this
ADR records the risk and the question, not an answer.

What it would take to make a decision — and the second half of this is new, because the first half
alone cannot close it:

**1. Measure the cost.** *Partly done — `scripts/write_durability_probe.exs` exists and has been
run on macOS. Linux numbers are still owed, and they are the ones that decide this.* See
"Measurements" below.

**2. Build a test that can fail.** *All three tiers built. Tiers 1 and 2 run locally and in CI;
tier 3 is CI-only and has not yet had a green run.*
**Killing the process proves nothing about fsync** — the page cache survives process death, so
every existing test passes under `:normal` and would keep passing under it no matter how wrong
`:normal` is. Two tiers, and the first one is now built:

- **Tier 1, the barrier assertion (built).** An `LD_PRELOAD` interposer records the cell's file
  I/O and its `fsync`/`fdatasync` calls in order, and the workload plants a marker in that same
  stream each time a write returns to Elixir. The assertion is then exactly the invariant: *if a
  commit's window wrote the WAL, a barrier on the WAL was requested after the last of those writes
  and before the acknowledgement.* Asserted in both directions — `:full` must have no violations,
  and `:normal` must have some, because a trace that captured nothing would otherwise pass. See
  "What tier 1 does not prove" below.
- **Tier 2, prefix replay (built).** The shim also captures write payloads, so the database and
  WAL can be reconstructed as they would have been had power failed at an arbitrary point.
  `scripts/barrier_test.sh --tier2`. Two assertions per cut, and the split between them matters:
  *every* cut must leave a database that opens and passes `PRAGMA integrity_check` — including
  under `:normal`, because `:normal` loses recent commits but must never corrupt — while only the
  commits that were both acknowledged and barriered before the cut are required to be *present*.
  The `-shm` is deliberately not restored: it is a volatile index a rebooted machine would not
  have, and carrying a reconstructed one across would let the replay recover from state that no
  longer exists.
- **Tier 3, the block layer (built, unverified).** `scripts/dm_log_writes_test.sh`, CI-only.
  `dm-log-writes` sits under the filesystem and records every bio with its flush and FUA flags, so
  `replay-log` reconstructs the device at any flush boundary. Its assertion is the one neither
  other tier can make: the surviving commits must be a **prefix** of the acknowledged sequence,
  not merely a subset. Commits 1, 2 and 4 surviving without 3 is a hole, and a hole means a write
  crossed a barrier it should not have — which is exactly the reordering tier 2's model assumes
  away.

Tier 3 is a *separate* job and non-blocking (`continue-on-error`) until it has passed once. It has
never run green, because it cannot run anywhere it could be developed against: Docker Desktop's
linuxkit kernel (6.12.76) carries neither `dm_log_writes` nor `dm_flakey`, and has no `modprobe`.
Until it goes green on a runner, a red result there is far more likely to be a setup problem than
a durability finding, and blocking merges on it would train everyone to ignore it.

One approach was considered and rejected on evidence rather than taste:

- **Killing a QEMU guest models a kernel panic, not power loss.** An earlier draft of this ADR
  called it "crude, real, and runnable". It is runnable, but with `cache=writeback` the guest's
  unflushed writes are in the *host* page cache, which survives `kill -9` on QEMU and gets written
  out anyway — so it tests strictly less than it appears to. Real semantics need `cache=none` plus
  a deliberately modelled volatile write cache.

### What these tiers do not prove

**Tiers 1 and 2 observe the process**, which is what lets them run without privileges. They see
what it asked the kernel for. Tier 1's pass means *the barrier was requested before the
acknowledgement*; tier 2's means *every prefix of those requests reconstructs to a database that
opens*. Neither means *the bytes are on the platter*.

**Tier 3 reaches the block layer** and closes the reordering gap, but not the last one: a drive
that acknowledges a flush it has not performed will satisfy every tier here. Nothing short of
pulling the plug on real hardware tests that, and it is not worth building — the failure it
describes is a firmware bug, and the mitigation is buying different disks, not writing different
code.

**And it cannot run on macOS at all**, which is worth stating plainly given the `fullfsync` finding
above: SIP strips `DYLD_INSERT_LIBRARIES` when exec'ing a protected binary, and both `mix`
(`#!/usr/bin/env bash`) and `erl` (`#!/bin/sh`) launch through one, so the variable never reaches
`beam.smp`. Measured directly — `DYLD_INSERT_LIBRARIES=… /usr/bin/printenv DYLD_INSERT_LIBRARIES`
prints nothing. So the platform where `:full` silently means `:normal` is the platform that cannot
run the test that would catch it. On a Mac the script re-execs itself in a container; CI runs it
natively.

The *judgement* is separated from the harness for this reason. `AshCell.BarrierTrace` decides
verdicts from a trace and is covered by `test/barrier_trace_test.exs` on every platform, including
the ordering cases that a naive "count the syncs in this window" check would get wrong. A
fault-injection harness whose verdict is quietly wrong reports a guarantee it never checked, which
is precisely the failure this ADR is about.

[ADR-11](ADR-11-simulate-the-protocol-only.md) is explicit that the simulator models the object
store and not fsync, so it will keep agreeing with itself regardless. Whatever closes this ADR has
to touch real I/O.

**3. Decide the shape**, between B and C, with the measurement in hand — and record which claims in
the docs and demo READMEs become conditional if C wins.

## Measurements

`scripts/write_durability_probe.exs`, 1000 single-row inserts, one writer, `pool_size: 1`, WAL,
`BEGIN IMMEDIATE` per batch. Reported as the min of 9 runs after a warmup, with the spread
(max/min) alongside, because a median alone was actively misleading here — see the note on method
below. **macOS 24.6 / APFS / aarch64, OTP 28.** These are not the numbers that decide the ADR.

| Level | µs/commit @ batch 1 | µs/row @ 1 | µs/row @ 10 | µs/row @ 100 |
|---|---|---|---|---|
| *statement floor* | 38 | 38 | 13.0 | 9.5 |
| `:off` | 57 | 57 | 19.9 | 13.6 |
| `:normal` | 70 | 70 | 18.3 | 13.2 |
| `:full` | 87 | 87 | 23.1 | 13.0 |
| `:full` + `fullfsync` | 4375 | 4375 | 430.5 | 52.3 |
| `:extra` | 97 | 97 | 18.6 | 12.5 |

Three things fall out, and only the third is about throughput.

**`:full` on macOS does not do the durable thing, and now there is a number for it.** `:full` sits
70 → 87 µs against `:normal`, a gap narrower than either row's run-to-run spread (1.9x and 2.0x).
Turning on `PRAGMA fullfsync` moves the same level to 4375 µs — **50x**. Darwin's `fsync` returns
without flushing the drive's write cache, so a developer machine set to `:full` is measuring
`:normal` and being reassured by the wrong number. This is the strongest argument yet that the
level cannot be validated on a laptop.

**The cost is per commit and independent of payload.** `:full` + `fullfsync` costs 4375, 4305 and
5226 µs per commit at batch 1, 10 and 100 — essentially flat, because it is one hardware cache
flush whatever is being flushed.

**So group commit amortises it almost perfectly**, which is the finding that changes the shape of
the decision. Per *row*, the same level falls 4375 → 430 → 52 µs as the batch grows 1 → 10 → 100.
Durability stops being a throughput question and becomes a batching question: the price of an
honest fsync is paid once per transaction, so an application that already groups its writes —
which `AshCell.transaction/2` exists to let it do — pays almost nothing for `:full`. This weakens
Option C considerably. Per-cell policy was motivated by `:full` being unaffordable for some
workloads; if batching makes it affordable, a uniform `:full` keeps `no_acknowledged_write_lost`
unconditional, which the ADR already argues is worth a lot.

### On the method, because the first version of this probe was wrong

Median of 5 was copied from [ADR-13](ADR-13-pool-size-one-and-cache.md) and did not survive
contact. The levels that do not fsync are dominated by DBConnection round-trips rather than by
SQLite — the statement floor row is 38 of `:normal`'s 70 µs — and on a laptop their run-to-run
variance reached **20x**: two consecutive runs put `:normal` at batch 1 at 123 ms and 2149 ms. A
median reported that as a result. The probe now reports min and spread, and the floor, so a gap
narrower than the noise is visible as one. A probe that hides its variance is worse than no probe,
and this one nearly shipped a fabricated ordering of `:off` against `:normal`.

## Consequences

- **What it rules out.** Nothing yet. No choice has been foreclosed.
- **What it makes worse.** Nothing yet, because nothing has changed.
- **What stays open.** Everything: whether `:normal` or `:full` is used, and by extension whether
  `no_acknowledged_write_lost` holds in production. This risk is live right now, not merely
  theoretical — the current default is `:normal`, unexamined, in a system whose DST suite cannot
  detect the gap because the simulator does not model fsync behaviour at all.
- **What now depends on it.** The `ledger` demo (`demos/ledger/docs/design.md`) depends on it
  directly and should not claim durability until this closes: an event store's entire contract is
  that the log is the truth, so a lost event there is not stale data but state that never happened,
  with balances already derived from it. More generally, every structure drafted in
  `docs/design/DD-05` through `DD-12` inherits whatever is decided here, and
  [DD-08](../design/DD-08-durable-execution.md) names this ADR as a hard gate on its own work.

## Evidence

- exqlite's default is `synchronous: :normal`; `cell.ex` does not override it.
- DST invariant `no_acknowledged_write_lost` and the simulator's model of the object store, not
  fsync behaviour, from [ADR-11](ADR-11-simulate-the-protocol-only.md).
- Probe: `scripts/write_durability_probe.exs`, min of 9 with spread, macOS only so far. See
  "Measurements" above. Linux/Fly numbers are the ones that decide this and have not been taken.
- Barrier test: `scripts/barrier_test.sh`, `test/fault/barrier_shim.c`, `AshCell.BarrierTrace`
  (tier 1) and `AshCell.BarrierReplay` (tier 2). Runs in CI (`durability-barrier`) and in Docker
  on macOS. Block layer: `scripts/dm_log_writes_test.sh`, CI job `durability-block-layer`,
  non-blocking until its first green run.
- The judgement in both local tiers is pure and covered natively by
  `test/barrier_trace_test.exs` and `test/barrier_replay_test.exs` — 28 tests, including a
  reconstruction round-tripped through a real SQLite database. A harness whose verdict is wrong
  reports a guarantee it never checked, and in tier 2 a bad reconstruction does not look like a
  bug: it looks like corruption, which is what the tier is hunting for.
- `dm_log_writes` and `dm_flakey` absent from Docker Desktop's linuxkit kernel 6.12.76, with no
  `modprobe` available — checked in a `--privileged` container, 2026-08-31.
- SIP strips `DYLD_INSERT_LIBRARIES` on exec of a protected binary; `mix` and `erl` both launch
  through `/bin/sh` or `/usr/bin/env`. Checked directly, 2026-08-31.
- `synchronous` is settable per connection: `deps/exqlite/lib/exqlite/connection.ex:115`
  (`:extra | :full | :normal | :off`, default `:normal`) and
  `deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:24`. `lib/ash_cell/cell.ex` passes neither, so
  every cell in the fleet currently runs `:normal` by omission rather than by choice. Read at
  exqlite 0.33 / ecto_sqlite3 0.21, 2026-08-25.
- **`synchronous` is already reachable without a code change, and this was measured rather
  than assumed.** `Ecto.Repo.Supervisor.init_config/4` merges the repo's application config
  *underneath* the options passed to `start_link/1` (`deps/ecto/lib/ecto/repo/supervisor.ex:29`),
  and `AshCell.Cell` passes no `synchronous`, so `config :my_app, MyApp.CellRepo, synchronous:
  :full` reaches exqlite. Probed against a live cell: `PRAGMA synchronous` returned `2`. This
  weakens the case for adding a DSL option now — Option C's per-cell policy is already
  expressible per repo module, and the open question is which level to *choose*, not how to set
  it. Documented in the README's "Durability on power loss" instead.
- **`journal_mode` was inherited, not chosen, and is now pinned.** `exqlite`'s default is
  `:delete` (`deps/exqlite/lib/exqlite/pragma.ex:15`); cells reached WAL only because
  `ecto_sqlite3` supplies it (`deps/ecto_sqlite3/lib/ecto/adapters/sqlite3/connection.ex:23`).
  This ADR's whole framing assumes WAL — `:normal` outside WAL risks corruption rather than a
  bounded loss — so the mode is now passed in `repo_opts`, above application config. Probed:
  config asking for `:delete` still opened `"wal"`.
- **The loss window under `:normal` is the WAL, not the last transaction.** In WAL mode
  `:normal` does not fsync at commit; it fsyncs at checkpoint, so the exposure is bounded by
  `wal_autocheckpoint` (~4 MiB) rather than by one commit. A fleet with a `:store` narrows this
  incidentally, because `AshCell.Replicator.snapshot/3` checkpoints before shipping and so
  fsyncs at least once per `max_age_ms`; a fleet with no store does not checkpoint until drain.
  This makes Option A's cost larger than "whatever exqlite's default throughput is" suggests.
- **Not verified, and it is the point of the plan above:** that `:full` actually survives a
  power-loss event on the target filesystem. macOS in particular has a history of `fsync` not
  reaching stable storage without `F_FULLFSYNC`, so "we set the pragma" is not evidence that the
  guarantee holds — only a fault-injection test is.

## Notes

Named as the top open risk on the project: "could lose data without anyone noticing." A future
revisit needs the throughput probe described above before this ADR can move to `accepted`.
