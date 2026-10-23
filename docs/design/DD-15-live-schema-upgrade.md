# DD-15 — Upgrading a running fleet's schema and code

**Status:** built
**Date:** 2026-10-22
**Decisions:** [ADR-31](../decisions/ADR-31-upgrade-resident-cells-in-place.md), [ADR-09](../decisions/ADR-09-snapshot-before-releasing-the-lease.md), [ADR-21](../decisions/ADR-21-close-does-not-await-the-connection.md), [ADR-26](../decisions/ADR-26-count-in-flight-work-at-the-pool.md)
**Lands in:** `test/live_upgrade_probe_test.exs`, `AshCell.upgrade/1`, `AshCell.Manager.reload_migrations/0`, `AshCell.Cell.migrate/3`, and a fix to `AshCell.Manager.migrate_all/2`

## What this is

A probe that starts a fleet of resident cells under continuous load from a v1 Ash resource, then delivers a v2 resource module and a new migration file to the same running BEAM node. It drives the upgrade three ways and counts what each one costs the load: code first, migration first, and expand-then-roll-then-load. The probe runs first against the library as it stands, so that every library change it motivates has a failing measurement in front of it.

## What this proves

1. A resident cell does not move schema version when new migration files arrive. `AshCell.Manager` compiles the migration list once in `init/1`, and a cell only migrates in `AshCell.Cell.init/1`.
2. Loading v2 code before every cell is at v2 fails requests against the cells that are not. The probe counts the failures per cell.
3. With an additive (expand) migration, every resident cell can be migrated in place while v1 code serves it, and v2 code can be loaded afterwards with zero failed requests. The probe reports each cell's pause.
4. A breaking migration (a rename, or a `NOT NULL` with no default) has no ordering of "migrate" and "load code" that avoids failures on one node, because one module version is current for every cell at once. The probe shows the failures in both orders.

## Why it needs a cell

A shared Postgres database migrates once per deploy. A cell fleet migrates once per cell, and the cells do not share a moment at which they change. Claims 1 and 3 exist because of that. Claim 4 holds for a shared database too, and expand/contract is the usual answer there. The cell-specific part of claim 4 is that the window is the time to roll every cell rather than the time to run one migration.

## Non-goals

- More than one node. A rolling deploy across nodes moves cells between old and new code through the drain, which is a different probe. This one keeps every cell on one BEAM node.
- OTP release upgrades (`relup`, `appup`). The probe loads new module versions with `Code.compile_string/2`, which is what a hot upgrade does to a module and nothing else.
- Running two versions of a resource at once, keyed by each cell's schema version. That is how claim 4 would be avoided without expand/contract. It is named in **Where it stops** and not built.
- Down migrations.

## Trade-offs

Three ways to bring a resident cell to the new schema:

| Way | Cost |
|---|---|
| Close it and let the next request reopen it | Needs the manager to know the new migrations. Reopening drops the page cache. Requests wait on `AshCell.Manager`'s activation call, which is serialised across the fleet. |
| Migrate it in place behind `AshCell.Registry.begin_closing/1` | Needs a new entry point. Requests wait on the closing gate, which gives up after a fixed 1s. |
| Leave it until it is next evicted | No pause, but v2 code cannot load until the last old cell goes, which may be never. |

The probe measures the first two.

## Measurements this must produce

Every run uses 8 resident cells, one writer and one reader process per cell issuing requests back to back, starting from one migration and adding a second. Each measurement is the range over 3 runs unless it says otherwise. The results are below each item, and [ADR-31](../decisions/ADR-31-upgrade-resident-cells-in-place.md) carries the full evidence.

- Failed requests per cell, and in total, for each of the four orderings (code first, breaking migration first, breaking code first, expand-roll-load).
  - Expand code first: 3346–4736 failed, spread evenly across cells.
  - Breaking, migrate first: 1691–2817 failed. Breaking, code first: 1417–2754 failed.
  - Expand, `AshCell.upgrade/1`, then load code: 0 failed of 3536–4921.
- The pause each cell sees during an in-place migration: the longest gap between two successful requests to that cell.
  - 0–12ms for an additive `ALTER TABLE`. The whole 8-cell upgrade took 60–96ms at concurrency 4.
  - A cliff, and its parameter is how long the migration holds the connection. At 1.5s and 3s the pause equals the hold and nothing fails. At 6s and 12s, DBConnection's default queue settings drop requests that waited 1.6–5.1s, 4–5 per cell (one run each).
- Activation latency of an unrelated cell while another cell's migration is running inside `AshCell.Manager`. This is a cliff, and the parameter that triggers it is the migration's duration.
  - 1461–1526ms during a 1500ms migration, against 1–7ms with nothing migrating.
- Whether `AshCell.Manager.migrate_all/2` reports the true schema version of a cell that was already resident.
  - Before the change it reported the version the cell opened at, `{:ok, 1}`, and closed the cell. It now migrates the cell in place, reports 2, and leaves it open.

## Staging

1. The probe against the library as it stands. Each claim above is a test, and the ones that need a library change are expected to show the gap.
2. The library changes the probe motivates, each with an ADR if it had a real alternative.
3. The probe again, asserting the graceful path: zero failed requests for expand-roll-load.

## Where it stops

- One node. Moving a migrated cell back to a node still running v1 code is not covered.
- Breaking migrations still fail on one node. The library can shorten the window but not close it, unless the application runs two versions of a resource, which this does not build.
- Cells that are not resident migrate when they next open, as before. The probe checks that they open at the new version, and nothing else about them. That migration still runs inside `AshCell.Manager`'s activation call, so after an upgrade each cold cell's first touch waits behind every other cold cell's migration.
- A `AshCell.ReadCache` projection built by v1 code stays cached after v2 code loads, until the cell's next write. The application invalidates its projections after loading code.
- A migration that holds a cell's connection for longer than about 3s drops queued requests with DBConnection's default queue settings. Long backfills belong in batches.

## Open risks

- `Code.compile_string/2` over a resource module that is already loaded builds the Ecto schema from the old module's attributes. A release loading prebuilt `.beam` files does not hit this, and the probe avoids it the same way. [ADR-31](../decisions/ADR-31-upgrade-resident-cells-in-place.md)'s Notes give the mechanism.
- An in-flight data-layer statement is invisible to the closing gate for the window [ADR-26](../decisions/ADR-26-count-in-flight-work-at-the-pool.md) measures. A migration that starts inside that window races one statement.
