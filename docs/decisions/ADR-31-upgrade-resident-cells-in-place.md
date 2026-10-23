# ADR-31 — Upgrade a running fleet by migrating resident cells in place, then loading code

**Status:** accepted
**Date:** 2026-10-22
**Deciders:** Conor Sinclair
**Relates to:** [DD-15](../design/DD-15-live-schema-upgrade.md) · [ADR-13](ADR-13-pool-size-one-and-cache.md) · [ADR-26](ADR-26-count-in-flight-work-at-the-pool.md) · `lib/ash_cell/manager.ex` · `lib/ash_cell/cell.ex` · `test/live_upgrade_probe_test.exs`

## The decision

To deliver a new migration and new code to a running node, the application writes the migration files, calls `AshCell.upgrade/1`, and loads the new code only once the report's `failed` is empty. `AshCell.upgrade/1` recompiles the fleet's migration list (`AshCell.Manager.reload_migrations/0`), so every cell activated from then on opens at the new version. It then migrates each resident cell in place on its own connection with `AshCell.Cell.migrate/3`, without closing it and without the closing gate. A cell whose migration fails is quarantined and closed, as at activation. This supports additive (expand/contract) migrations only. A breaking migration fails requests on one node in either order, and the library does not try to hide that.

## Context

`AshCell.Manager` compiled the migration list once, in `init/1`, and a cell migrated only in `AshCell.Cell.init/1`. A migration file delivered to a running node was therefore never applied: not to a resident cell, not to one closed and reopened, and not to one opened for the first time. `AshCell.Manager.migrate_all/2` reported a resident cell's version from when it opened, which was stale, and then closed it while it was serving. The probe in `test/live_upgrade_probe_test.exs` measured each of these before anything changed.

The other half of an upgrade is code, and on one BEAM node one version of a resource module is current for every cell at once. Loading v2 code before a cell is at v2 fails that cell's requests. Loading it after fails nothing only when v1 code also works against the v2 schema.

## Options considered

### Option A — close each resident cell and let the next request reopen it

Needs only `reload_migrations/0`. Reopening drops the page cache and the read cache. The reopen runs the migration inside `AshCell.Manager`'s `{:start, ...}` call, which serialises every activation on the node: the probe measured an unrelated cell taking 1492ms to activate during a 1500ms migration, against 5ms with nothing migrating. Rolling a fleet this way puts every cold activation behind every migration. Lost.

### Option B — migrate in place behind `AshCell.Registry.begin_closing/1`

Holds new binds while the migration runs. The gate's waiter, `AshCell.await_not_closing/2`, gives up after a fixed 1s and returns `{:error, :cell_closing}`, so any migration longer than that becomes errors. The gate adds nothing that the cell's connection pool does not already do. With `pool_size: 1`, the migration's transaction holds the one connection and every statement for that cell queues behind it. Lost.

### Option C — migrate in place on the cell's own connection, ungated (taken)

The pool of one is the gate. Measured: an additive migration across 8 resident cells under one writer and one reader per cell took 60–96ms in total, paused each cell 0–12ms, and failed 0 of 3536–4921 requests over 3 runs.

The migration runs in a `Task` started by the cell process, not in `handle_call/3`. A request reaches its repo pid through `AshCell.Cell.repo_pid/1`, a call to the cell. Run inside the call, the migration waited on the connection while a writer holding it inside `BEGIN IMMEDIATE` waited on the cell. Every expand and slow run then failed with DBConnection dropping the migration after about 4s. Reading the repo pid from the registry value instead broke "concurrent binders all survive repeated eviction" in `test/regression_test.exs` 5 times out of 5 and was reverted. The cell queues a second `migrate/3` behind the first, so two upgrades of one cell run in order.

### Option D — run v1 and v2 resource modules side by side, chosen per cell by schema version

The only option that would let a breaking migration roll without errors on one node. The application would have to name two modules and route every call by the cell's version, and a cached projection would carry the version in its name. Not built. It is application design rather than a library change, and nothing here needs it yet.

## Decision and why

Option C, because it was the only one measured at zero failed requests and it adds one entry point rather than a new gate. The ordering rule for code falls out of claim 4 in DD-15: with a rename, migrating first failed 1691–2817 requests and loading code first failed 1417–2754, across 8 cells, over 3 runs. Expand/contract is what makes the order safe, and the library says so in `AshCell.upgrade/1`'s doc.

`upgrade/1` lists resident cells after the reload, not before. A cell activating at the same moment is then either registered already, so it is listed, or started by the Manager after the reload, so it opens with the new list. Listing first would let one open at the old version between the two steps.

## Consequences

- **What it rules out.** Breaking migrations with no failed requests on one node. Use expand, upgrade, load code, then contract in a later upgrade.
- **What it makes worse.** A cell's requests pause for as long as its migration holds the connection. DBConnection's default queue settings (`queue_target` 50ms, `queue_interval` 2000ms) make that a cliff, not a slope. With a 1.5s or 3s migration nothing failed. With 6s or 12s, requests that had waited 1.6–5.1s were dropped: 4–5 per cell with two clients per cell. A long backfill belongs in batches, not in one migration.
- **What stays open.** Cold activation still migrates inside the Manager's call, so after an upgrade the first touch of each non-resident cell serialises behind the others' migrations (Option A's 1492ms measurement). A cached `AshCell.ReadCache` projection built by v1 code stays cached after v2 code loads, until the cell's next write. `AshCell.Cell.migrate/3` invalidates the cell's cache when its migration finishes, which is before the code loads. The application owns that invalidation. Moving a migrated cell to a node still on v1 code is not covered.
- **What now depends on it.** `AshCell.Manager.migrate_all/2` migrates an already-resident cell through `AshCell.Cell.migrate/3` and leaves it open.

## Evidence

All in `test/live_upgrade_probe_test.exs`, 8 cells, one writer and one reader process per cell issuing requests back to back, no object store:

- "a resident cell does not move version when a migration file arrives": closed and reopened, the cell is still at 1. A cell never opened before also opens at 1.
- "loading expand code before migrating fails requests on unmigrated cells": 3346–4736 failed requests over 3 runs, `no such column: u0.sku`, on reads as well as writes.
- "a breaking migration fails in both orders": the numbers above.
- "expand migration under v1 load, run in place, costs no failures": the numbers in Option C.
- "a slow in-place migration under load": `LU_SLOW_MS` sets the migration's hold. 1500 and 3000 gave 0 failures and pauses equal to the hold. 6000 gave 32 failures and 12000 gave 40, all `DBConnection.ConnectionError` "request was dropped from queue after" 1649–5127ms. One run each above 1500.
- "a migration that fails in one cell quarantines that cell and migrates the rest": `{:migration_failed, 2, RuntimeError}` for the one cell, which was not resident afterwards, while the other 7 migrated.
- "a slow migration in one cell delays activation of every other cell": 1461–1526ms against a 1–7ms control.

Not verified: the queue settings' effect with more than two clients per cell, and any OTP release upgrade (`relup`). The probe loads module versions with `:code.load_binary/3`.

## Notes

Hot loading an Ash resource has a trap of its own. `Code.compile_string/2` over a resource module that is already loaded builds an Ecto schema from the *old* module's attributes. `Ash.Resource.Schema` reads `Ash.Resource.Info.attributes/1` while compiling, and Spark's `get_config_entry_with_fallback/6` reaches the loaded module first. After the recompile, `Ash.Resource.Info.attribute(mod, :sku)` found the attribute, while `__schema__(:fields)` was still `[:id, :name]`. Every create then failed with `unknown field :sku`. A release loads prebuilt `.beam` files and does not hit this, so the probe purges each version before compiling the next and swaps them with `:code.load_binary/3`.
