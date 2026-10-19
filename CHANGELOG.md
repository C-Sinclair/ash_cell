# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

AshCell is pre-1.0 and experimental. The API is not stable; breaking changes go
out in a minor version bump and are called out here with what to change.

## [Unreleased]

### Added

- **`AshCell.claim/2`.** Takes a cell's lease on this node, restores its newest
  snapshot when the lease was taken rather than renewed (or when there is no
  local file), and opens it. `AshCell.Lease.claim/4` reports which happened as
  `renewed?`.

### Changed

- **Upstream `ash_sqlite`, not the fork.** AshCell pins `ash-project/ash_sqlite`
  at `701530c` (PR #246 merged) and requires ash `~> 3.33 and >= 3.33.2`. Define a cell repo with
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
- **A cell repo starts its own fleet.** Put `MyApp.CellRepo` in the supervision
  tree with its options under `tenants:` (in the repo's application env, or as
  the child's option) instead of `{AshCell, repo: MyApp.CellRepo, ...}`. That
  child spec still works.
- **`:key_for` is gone; a cell's key comes from the repo's `init/2`.** Each cell
  starts its repo instance with `tenant:` set to its cell key. Set `:key` from
  `config[:tenant]` in an `init/2` override before calling `super/2`, and mark
  the fleet `encrypted?: true` to keep refusing a cell with no key.
- **Cells migrate from Ecto migration files.** `AshCell.Migrator` and the
  `:migrator` option are gone. Put `<version>_<name>.exs` files, each an
  `Ecto.Migration`, in a directory and pass it as `tenants: [migrations_path: ...]`.
  A cell migrated by `AshCell.Migrator` records every file up to its `PRAGMA
  user_version` as run on first open, so give each old migration the same number.
  `AshCell.Stream.migrate/1` is now `AshCell.Stream.Migration.up/0`, called from a
  migration's `up/0`. Because `Ecto.Migrator` reads `repo.config/0`, a cell repo's
  `init/2` also runs with no `:tenant`, so a key function must allow `nil`.
- **Cell keys encode as `AshSqlite.MultiTenancy` encodes tenants.** Uppercase
  letters are escaped and the hex is lowercase, so `"Acme"` is `~41cme.db`. The
  old encoding let `"Acme"` and `"acme"` share one file on a case-insensitive
  filesystem. A cell key containing uppercase letters or escaped bytes now names a
  different file and object-store prefix, so existing cells with such keys must be
  renamed, or restored under the new prefix, before they are opened. A key that
  encodes to more than 244 bytes is refused.
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
- **Per-cell migrations.** Each cell runs the fleet's Ecto migration files on
  activation. A cell whose
  migration fails is quarantined. `mix ash_cell.migrate` migrates eagerly.
- **Encryption at rest.** The repo's `init/2` opens each cell under that
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
