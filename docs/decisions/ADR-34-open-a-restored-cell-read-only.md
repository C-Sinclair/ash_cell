# ADR-34 — Open a restored cell read-only, and refuse its writes in the binder

**Status:** accepted
**Date:** 2026-11-01
**Deciders:** Conor Sinclair
**Relates to:** `AshCell.open_read_only/1`, `AshCell.Binder`, `AshCell.Cell`, [ADR-02](ADR-02-bind-in-the-data-layer.md), [ADR-33](ADR-33-renew-leases-from-one-process-per-fleet.md)

## The decision

`AshCell.open_read_only/1` restores a cell's newest snapshot and opens it with a SQLite connection in `mode: :readonly`. The cell skips migrations and periodic shipping. `AshCell.Binder.tenant_repo/2` raises `AshCell.ReadOnlyCellError` for a `:mutate` statement against it before the statement reaches SQLite. The manager remembers the mode per cell key, so a read-only cell reopens read-only after a close, until `AshCell.claim/2` clears it.

## Context

DataLite's phone serves reads from a restored copy of a cell that the Mac or Hermes writes. Before this, any node could open any cell. A write on a node without the lease landed in a local file that never shipped, because shipping needs a lease txid. Nothing raised.

## Options considered

### Option A — the SQLite connection alone

`mode: :readonly` stops every write, including raw Ecto through `AshCell.with_tenant/2`. On its own, an Ash write fails with an `Exqlite.Error` reading "attempt to write a readonly database". That message does not say what to do.

### Option B — the binder alone

`tenant_repo/2` already receives `type: :mutate` for every write, and is the one place that sees every Ash statement ([ADR-02](ADR-02-bind-in-the-data-layer.md)). Refusing there gives a named error. It does not cover `with_tenant/2`, which binds without the data layer.

### Option C — both (taken)

The binder gives Ash callers a clear error. The connection mode covers raw writes.

### Option D — a separate API on `AshCell.Branch` or the replicator

`AshCell.Branch` copies a snapshot into a new cell key. A read copy keeps the same key, so the application's tenant does not change. `AshCell.Replicator.restore/3` only writes a file and opens nothing, which is why the gap existed.

## Decision and why

Option C. It names the cause for Ash callers and leaves no write path open.

A read-only cell skips migrations, because migrating needs writes. It serves the schema the snapshot was shipped with, and `schema_version` comes from `schema_migrations` without creating the table. `open_read_only/1` refuses while this node holds the lease, in the manager or in the store, because restoring would replace writes it has not shipped.

## Consequences

- **What it rules out.** A stray write landing silently in a copy that never ships.
- **What it makes worse.** A read copy is as stale as the newest snapshot, and nothing refreshes it. The application calls `open_read_only/1` again to read a newer one.
- **What stays open.** A snapshot shipped before a migration is served at its old schema. Code reading a read copy must tolerate that version window.
- **What now depends on it.** `AshCell.claim/2` closes a read-only cell before it opens it under the lease.

## Evidence

- `test/read_only_test.exs`: an Ash write raises with `AshCell.ReadOnlyCellError` in its message, a raw insert raises `Exqlite.Error` "readonly", the mode survives a close, `claim/2` makes the cell writable, the call is refused under the lease, and a drain closes a read-only cell without reporting a failure.
- Exqlite's `:mode` option is documented in `deps/exqlite/lib/exqlite/connection.ex`. A read-only open of a restored WAL database with no `-wal` or `-shm` worked in these tests on macOS. It was not tried on Android.

## Notes

Asked for by DataLite (`docs/designs/2026-11-01-phone-read-copy-and-write-lease.md` in that repo, section "Read copy").
