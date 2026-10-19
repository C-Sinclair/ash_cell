# ADR-07 — Key cells by an opaque cell key, and encode it injectively

**Status:** accepted
**Last changed:** 2026-10-19 — the encoding was not injective on a case-insensitive filesystem, and is replaced by the one `AshSqlite.MultiTenancy` uses (ash_sqlite PR #246). Uppercase letters passed through, so `"Acme"` and `"acme"` became `Acme.db` and `acme.db`, which are one file on APFS and NTFS. Measured on this project's own macOS workstation: a row written to cell `"Acme"` was read back from cell `"acme"`. The new encoding escapes uppercase, uses lowercase hex, and refuses a key that encodes to more than 244 bytes. Cell keys containing uppercase letters or escaped bytes now map to different file names and object-store prefixes than before.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · [ADR-05](ADR-05-refuse-cross-cell-transactions.md) · [ADR-19](ADR-19-the-cell-cut-is-a-choice.md)

## The decision

Resolve Ash's tenant to a cell key once, at `AshCell.bind/1`, via `AshCell.CellKey.resolve/1`, and
treat the cell key as opaque everywhere below the binder — Registry key, file path, S3 prefix,
lease key. Encode that key injectively with `AshCell.CellKey.encode/1` rather than sanitising it,
and injectively on a case-insensitive filesystem too. Use the same encoding as
`AshSqlite.MultiTenancy`, so a cell key and an AshSqlite tenant with the same value name the same
file.

## Context

Tenant-to-storage-identity had been one implicit identity function. `tenant` was already opaque
throughout the storage layer, so the only real coupling was `VerifyMultitenancy`'s hardcoded
assumption of one database per tenant. Naming the resolver step reframed "alternative
architectures" as "alternative keys", and exposed three meanings sharing one word: Ash's tenant
vocabulary (unchanged at the Ash-facing edges — `tenant_repo/2`, `Binder`,
`Resource`, `LiveView`, `Job`); AshCell's `cell_key`; and the resolver between them.

Two real bugs forced the injectivity requirement, not taste. `Manager` interpolated the raw key
into `Path.join/2` (`manager.ex:314`), so a key of `"../../etc/x"` wrote outside the cell
directory — path traversal. Lease and snapshot object keys interpolated unescaped too, so a key
containing `/` forged object-store prefixes.

## Options considered

### Option A — resolver signature `query -> cell key`

Lets a resolver route on more than the tenant value. Rejected: the data layer asks for a
connection once per statement, so a query-dependent resolver could route two statements of one
action to two cells, and a transaction cannot span two cells ([ADR-05](ADR-05-refuse-cross-cell-transactions.md)).
Cost: none avoided, only deferred to a place that cannot honour it.

### Option B — sanitise awkward bytes instead of escaping

Replace characters like `:` with `_` to build a filename. Costs correctness: it maps `"a:b"` and
`"a_b"` to one file, so two cells share a database and rows cross the isolation boundary with
nothing raising.

### Option C (chosen) — resolver signature `tenant -> cell key`, escape rather than sanitise

The resolver sees the tenant and deliberately not the query. The application names the cut in the
tenant value instead, e.g. `"acme:2026-08"`. Encoding is injective: `~` plus lowercase hex keeps it
reversible — `acme:2026-08` → `acme~3a2026-08`, and `Acme` → `~41cme`.

Until 2026-10-19 uppercase letters passed through and the hex was uppercase. That kept more keys
readable, and it was injective as a function on strings. It was not injective as a function onto
files on a case-insensitive filesystem, which is the default on macOS and Windows.

### Option D — escape on a case-insensitive filesystem only

Detect the filesystem's case behaviour and escape uppercase only where it folds case. Rejected:
the object store and the file name would then disagree between two nodes on different
filesystems, and a cell copied from one to the other would change name. Cost: any code that builds a cell key from a
tenant string must go through resolution rather than string-building it directly.

## Decision and why

The resolver boundary is placed at `bind/1`, once per bind, because that is the one point that
sees the tenant and not yet the query — matching the constraint from ADR-05 that a transaction
cannot span two cells. Injectivity is chosen over sanitising because the two path-traversal and
prefix-forging bugs were real, found in the existing code, and both stem from the same root cause:
a non-injective mapping from key to filesystem/object-store path.

## Consequences

- **What it rules out.** A resolver that varies by query shape within one action; per-statement
  cell routing inside a single Ash action.
- **What it makes worse.** Anywhere a tenant and a cell key were previously interchangeable now
  needs to pick the right vocabulary. The public API mixes vocabularies by design:
  `with_tenant/2` and `AshCell.Job.perform_for_tenant/2` keep tenant names because they take and
  resolve tenants; `bound_cell/0`, `resident_cells/0`, `drain_cell/3`, and `fleet/0`'s `cell_key`
  report cell-key names.
- **What stays open.** `VerifyMultitenancy`'s error message no longer asserts one-database-per-
  tenant as law, but nothing yet documents the full set of valid cell-key shapes for a resolver
  author.
- **What now depends on it.** `Replicator`, which previously called `AshCell.checkpoint/1` and
  re-resolved a cell key as a tenant — a no-op under the default resolver, wrong under any other.
  Fixed by adding `bind_cell/1`, `with_cell/2`, `checkpoint_cell/1`. ADR-19's alternative cell cuts
  (per entity, per time window, per workload) depend on the key staying opaque and the resolver
  seeing only the tenant.

## Evidence

- `test/cell_key_test.exs` `AshCell.CellKeyFilesTest` "keys that differ only by case get separate
  databases": with the earlier encoding, on APFS, cell `"Acme"` read back both its own row and
  `"acme"`'s. It passes with the current one. On a case-sensitive filesystem, such as Linux CI,
  it passes either way, so `AshCell.CellKeyTest` also checks that two keys differing only by case
  still differ after lowercasing their encodings.
- The encoding matches `AshSqlite.MultiTenancy`'s `encode/1` in ash_sqlite PR #246, checked by test
  vectors copied from it (`"a:b"`, `"a_b"`, `"../../etc/x"`, `"Acme"`). Not verified by calling
  that function, which is private and not in a release.
- `AshCell.CellKey.resolve/1`, called once at `AshCell.bind/1`.
- `AshCell.CellKey.encode/1`: 16 new tests, adversarial distinctness plus round-trip. Suite went
  171 → 207+.
- Bugs fixed: `manager.ex:314` (`Path.join/2` path traversal); unescaped lease/snapshot object
  keys.
- Renames: `bound_tenant/0` → `bound_cell/0`, `resident_tenants/0` → `resident_cells/0`,
  `drain_tenant/3` → `drain_cell/3`.
- Commits: `ca94f84`, `6aff105`.

## Notes

The rejected `query -> cell key` resolver signature is the same shape of mistake ADR-05 rules out
for transactions — both attempt to make a single Ash action span more than one cell.
