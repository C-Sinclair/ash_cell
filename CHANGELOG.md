# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

AshCell is pre-1.0 and experimental. The API is not stable; breaking changes go
out in a minor version bump and are called out here with what to change.

## [Unreleased]

### Changed

- **Upstream `ash_sqlite`, not the fork.** AshCell pins `ash-project/ash_sqlite`
  at `d200a69` and requires ash `~> 3.33 and >= 3.33.2`. Define a cell repo with
  `use AshCell.Repo` instead of `use AshSqlite.Repo`; it implements
  `tenant_repo/2` and returns `true` from `write_transactions?/0`. A shared-table
  repo that needs transactions defines `write_transactions?/0` itself.
- **`AshCell.Resource` no longer sets anything.** The `tenant_binder` and
  `write_transactions?` DSL options are gone upstream, and Ash now passes the
  tenant to `transaction/4`, so the transformer and
  `AshCell.Resource.Changes.CarryTenant` are deleted. The extension is a
  compile-time check for `strategy :context`.
- **`AshCell.Binder.tenant_repo/2` replaces `bind/3`.** The drain's in-flight
  count is read from each cell's connection pool, the read cache's write bracket
  is closed from the repo's query telemetry, and `AshCell.bound_cell/0` is read
  off Ecto's binding. `AshCell.ReadCache.start_link/1` takes `repo:`.
- **A resource without `strategy :context` on a cell repo is refused.** AshSqlite
  reports it at compile time and raises on its first statement. It used to follow
  whatever cell the process had bound.

## [0.1.0] - unreleased

Not yet published to Hex. AshCell depends on `ash_sqlite` from git until upstream
releases `tenant_repo/2`, and Hex refuses a package with a git dependency.
Install from git in the meantime; see the README.

The working tree implements:

### Added

- **Cells.** One encrypted SQLite file per tenant, opened by one process at a
  time, under a supervised fleet with an LRU residency bound (`AshCell`,
  `AshCell.Manager`, `AshCell.Cell`).
- **`AshCell.Repo` and `AshCell.Resource`.** A cell repo answers AshSqlite's
  `tenant_repo/2` and turns transactions on; the resource extension checks for
  `strategy :context`. Ordinary Ash calls with `tenant:` then work from any
  process, with no binding by the caller.
- **Cell keys.** `AshCell.CellKey` resolves Ash's tenant to an opaque cell key,
  so the cut can be per tenant, per entity, or per time window without a code
  change. Encoding is injective, so two keys can never share a file.
- **Transactions.** Multi-statement atomicity within one cell via
  `AshCell.transaction/2`, using `BEGIN IMMEDIATE`. A transaction spanning two
  cells is refused rather than silently non-atomic.
- **Per-cell migrations.** `AshCell.Migrator` versions each cell against
  `PRAGMA user_version` and applies migrations on activation. A cell whose
  migration fails is quarantined. `mix ash_cell.migrate` migrates eagerly.
- **Encryption at rest.** A `:key_for` callback opens each cell under that
  tenant's own SQLCipher key. `mix cipher.check` guards the silent failure mode
  where `exqlite` was built without SQLCipher.
- **Replication and ownership.** Snapshots to S3-compatible storage
  (`AshCell.Replicator`, `AshCell.ObjectStore`), with single-writer ownership
  enforced by conditional writes. Fencing is keyed by a txid namespace every
  owner shares, so a displaced writer finds out before acknowledging
  (`AshCell.Lease`).
- **Drain.** `AshCell.drain/0` seals, checkpoints, snapshots and releases the
  lease for every resident cell, so a successor does not wait out the TTL.
- **Integration points.** `AshCell.LiveView` for per-callback binding and holder
  registration, `AshCell.Job` for Oban workers that carry a tenant rather than
  inheriting one, and `AshCell.Plug.OwnerRouting` for routing a request to the
  node that holds the cell.
- **Read cache.** `AshCell.ReadCache` for reads that must not open a cell.

[Unreleased]: https://github.com/C-Sinclair/ash_cell/compare/main...HEAD
