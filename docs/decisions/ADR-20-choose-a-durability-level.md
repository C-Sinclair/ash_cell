# ADR-20 — Choose SQLite's durability level (`synchronous`)

**Status:** accepted
**Last changed:** 2026-10-22 — accepted as Option B. `AshCell.Repo` gives every cell `synchronous: :full` unless its repo chose a level, following the power-loss replay below.
**Previously changed:** 2026-10-21 — the cost is measured on Linux, and the power-loss test is built and run (`scripts/power_loss/run.sh`, the `durability` CI job). On a Linux runner `:normal` lost every acknowledged commit in all 20 replayed power cuts, and `:full` lost none. The decision between B and C is still to be made.
**Previously changed:** 2026-10-21 — the cost is now measured on macOS (`scripts/synchronous_probe.exs`, below). It shows that on macOS the price of durability is `fullfsync`, not `synchronous`, and that group commit amortises it. Linux is still unmeasured, and the power-loss test is still unbuilt, so no decision yet.
**Previously changed:** 2026-08-25 — added Option C (per-cell policy), and the argument that a throughput
measurement is necessary but *not sufficient* to close this: it needs a test that can fail.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-11](ADR-11-simulate-the-protocol-only.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md) · [ADR-13](ADR-13-pool-size-one-and-cache.md) · [ADR-19](ADR-19-the-cell-cut-is-a-choice.md) · `demos/ledger/docs/design.md`

## The decision

Run every cell at `synchronous: :full`. `AshCell.Repo.check_init/2` sets it with `Keyword.put_new/3`, so a repo that names a level in its config or its `init/2` keeps that level. `:full` is the default, not a requirement. A repo choosing `:normal` for a cell whose contents can be rebuilt is an explicit choice made at the repo.

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
What it costs: about 220 µs a single-row commit on a Linux runner, and about 3.9 ms on macOS with `fullfsync`. See the measurement sections below. The cost is paid by every cell, including ones whose contents are a cache, unless their repo opts down.

This is the option taken.

### Option C — durability as a per-cell policy

`synchronous` is a connection option — `:extra | :full | :normal | :off`,
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

The power-loss replay settled it. Under `:normal`, every one of 20 replayed power cuts lost acknowledged commits: the cell held the schema and none of the rows it had acknowledged. Under `:full`, none of 20 lost anything. A default that loses acknowledged writes to a power cut, with nothing raising, is the failure this project exists to avoid.

The cost is real but bounded. On Linux `:full` takes a single-row commit from about 49 µs to about 271 µs, so one cell does about 3,700 single-row commits a second instead of about 20,000. The fsync is paid per commit, not per row, so a cell that batches recovers most of it: at 100 rows a transaction `:full` writes about 248,000 rows a second. Cells are separate files, so the total fsync count grows linearly with total commits across the fleet.

Option C, per-cell policy, is available without being the default: a repo's `init/2` sees the cell key and can set `:synchronous` per cell. The default had to be the safe one. A cell that loses data should be one somebody chose to make lossy.

How it was decided, kept because the method is reusable:

**1. Measure the cost.** `scripts/synchronous_probe.exs`, median of 5, on macOS and on Linux, including group commit.

**2. Build a test that can fail.** Killing the process proves nothing about fsync, because the page cache survives process death. `scripts/power_loss/run.sh` records the block writes through `dm-log-writes` and replays them to each acknowledged commit instead. [ADR-11](ADR-11-simulate-the-protocol-only.md)'s simulator models the object store and not fsync, so it could not have closed this.

## Measured cost on macOS

`scripts/synchronous_probe.exs`, 2026-10-21: one WAL-mode file per level on an APFS SSD (macOS, OTP 28, exqlite 0.39), 500 transactions per run, median of 5 runs. µs per transaction, with p99 from the median run.

| Inserts per transaction | `:normal` | `:full` | `:full` + `fullfsync` | `:extra` + `fullfsync` |
|---|---|---|---|---|
| 1 | 10 (p99 84) | 47 (p99 228) | 3,890 (p99 4,112) | 3,944 (p99 5,346) |
| 10 | 25 (p99 47) | 55 (p99 195) | 3,903 (p99 4,274) | 3,950 (p99 8,371) |
| 100 | 293 (p99 1,376) | 247 (p99 913) | 4,002 (p99 9,951) | 8,064 (p99 18,903) |

What this shows:

- On macOS `:full` alone costs about 37 µs a commit, and buys little, because `fsync` there does not force the drive's cache to stable storage. Only `PRAGMA fullfsync = ON` issues `F_FULLFSYNC`, and that costs about 3.9 ms a commit: roughly 257 single-row commits a second for one cell, whatever the level.
- The fsync is paid per commit, not per row. At 100 rows a transaction, `:full` with `fullfsync` writes about 25,000 rows a second. Group commit is what makes durability affordable here, not the choice of level.
- This is one machine. Linux `fsync` does reach stable storage on most drives without an extra flag, so its `:full` cost is expected to sit between these two columns. That is an expectation, not a measurement, and the production decision depends on it.

Still owed: the same probe on the disk type production uses.

## Measured cost on Linux

The same probe in the `durability` CI job, 2026-10-21, on a GitHub Actions `ubuntu-latest` runner (Azure VM disk, ext4, OTP 28.1.1), CI run 39661730776. Same shape: 500 transactions per run, median of 5 runs, p99 from the median run. One CI run, so one machine.

| Inserts per transaction | `:normal` | `:full` | `:full` + `fullfsync` | `:extra` + `fullfsync` |
|---|---|---|---|---|
| 1 | 49 (p99 68) | 271 (p99 4,809) | 273 (p99 1,101) | 286 (p99 9,899) |
| 10 | 32 (p99 55) | 295 (p99 799) | 278 (p99 1,242) | 264 (p99 6,123) |
| 100 | 186 (p99 271) | 404 (p99 5,592) | 403 (p99 1,837) | 402 (p99 2,571) |

What this shows:

- On Linux `:full` costs about 220 µs a commit over `:normal`. That is about 3,700 single-row commits a second for one cell, against about 20,000 at `:normal`.
- `fullfsync` changes nothing on Linux, as expected. It is a macOS-only pragma.
- The p99 at `:full` reaches about 5 ms. Group commit amortises the fsync here as on macOS: at 100 rows a transaction `:full` writes about 248,000 rows a second.
- A cloud VM disk is not the production disk. The production number is still owed.

## Power-loss replay

`scripts/power_loss/run.sh`, in the same CI run. A real cell (`AshCell.Test.BoundPatient` on `AshCell.TestRepo`) writes 200 single-row commits onto ext4 over a `dm-log-writes` device. After each commit returns, the writer puts a mark in the block log. The script replays the log up to every 10th mark onto a blank device, mounts it, and checks the cell with `PRAGMA integrity_check` and a row count. Each replay is the disk as a power cut at that mark would leave it.

| `synchronous` | Power cuts replayed | Lost acknowledged commits | Integrity failures |
|---|---|---|---|
| `:normal` | 20 | 20 (every replay held 0 of its acknowledged rows) | 0 |
| `:full` | 20 | 0 | 0 |

What this shows:

- Under `:normal`, which every cell runs today, a power cut loses acknowledged commits. In this run it lost all of them: the whole writer finished before the kernel wrote any WAL page back, so every replay held the schema and no rows. The window on a real machine is the kernel's writeback delay, not the length of this run. That window was not measured.
- Under `:full`, every replay held every row acknowledged before its mark.
- No replay corrupted the database at either level. `:normal` loses commits. It does not corrupt the file.
- The test can fail, which was the gap step 2 named. It fails on `:normal` and passes on `:full`, so it tells the two levels apart.

## Consequences

- **What it rules out.** Silent loss of acknowledged commits to a power cut or kernel crash on a cell's own disk, for any cell whose repo does not opt down.
- **What it makes worse.** Single-row write throughput per cell falls by about five times on a Linux runner. Write-heavy cells that do not batch will notice. On network block storage every commit's fsync uses the volume's IOPS allowance.
- **What stays open.**
  - The cost on the disk production uses. The runner is a cloud VM disk.
  - How many cells committing at `:full` at once one disk sustains. The probe measures one file at a time.
  - Loss of the node or its disk. `:full` makes the local disk trustworthy. Writes since the last snapshot are still lost if the disk is gone, because snapshots ship on a schedule ([ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md)). Closing that is Path B in [`docs/spec.md`](../spec.md), still deferred.
- **What now depends on it.** The `ledger` demo design and [DD-08](../design/DD-08-durable-execution.md), which named this ADR as a gate. `scripts/power_loss/run.sh` and the `durability` CI job, which fail if `:full` ever loses a commit. `test/synchronous_test.exs`, which checks the pragma a cell ends up with.

## Evidence

- exqlite's default is `synchronous: :normal`. `AshCell.Repo.check_init/2` overrides it to `:full` unless the repo set a level, checked by `test/synchronous_test.exs`.
- DST invariant `no_acknowledged_write_lost` and the simulator's model of the object store, not
  fsync behaviour, from [ADR-11](ADR-11-simulate-the-protocol-only.md).
- `:normal` versus `:full` is measured on macOS only; see *Measured cost on macOS*.
- `synchronous` is settable per connection: `deps/exqlite/lib/exqlite/connection.ex:115`
  (`:extra | :full | :normal | :off`, default `:normal`) and
  `deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:24`. Read at
  exqlite 0.33 / ecto_sqlite3 0.21, 2026-08-25.
- `:full` survives replayed power cuts on ext4 over a Linux block device, and `:normal` does not: the *Power-loss replay* section above, CI run 39661730776.
- **Not verified:** that `:full` survives a power-loss event on the production filesystem and disk. macOS in particular has a history of `fsync` not
  reaching stable storage without `F_FULLFSYNC`, so "we set the pragma" is not evidence that the
  guarantee holds — only a fault-injection test is.

## Notes

Named as the top open risk on the project before it was accepted: "could lose data without anyone noticing." Until 2026-10-22 every cell ran `:normal` by omission, because `lib/ash_cell/cell.ex` passed no level.
