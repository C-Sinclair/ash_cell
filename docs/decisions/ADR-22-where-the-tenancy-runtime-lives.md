# ADR-22 — Where the database-per-tenant runtime lives: the fork or AshCell

**Status:** proposed — direction settled, seam open
**Last changed:** 2026-08-24 — reframed: the fork's tenancy layer is deliberate, upstream-bound work, not a collision. What is open is how much of it AshCell reuses, not whether it should exist.
**Date:** 2026-08-24
**Deciders:** Conor Sinclair (owns both repos)
**Relates to:** [`ADR-02`](ADR-02-bind-in-the-data-layer.md), [`ADR-03`](ADR-03-fork-ash-sqlite-narrowly.md), [`ADR-07`](ADR-07-opaque-cell-keys.md), [`ADR-09`](ADR-09-snapshot-before-releasing-the-lease.md), [`ADR-10`](ADR-10-fail-closed-on-a-refused-shipment.md), [`ADR-19`](ADR-19-the-cell-cut-is-a-choice.md), [`../design/DD-01-cell-runtime.md`](../design/DD-01-cell-runtime.md), [`../design/DD-03-tenant-binding.md`](../design/DD-03-tenant-binding.md), `lib/ash_cell/manager.ex`, `lib/ash_cell/cell.ex`, `lib/ash_cell/registry.ex`, `lib/ash_cell/cell_key.ex`

## The decision

**AshCell keeps supplying its own `AshSqlite.TenantBinder` rather than relying on the fork's
default.** The fork is deliberately growing its own database-per-tenant engine, and that engine is
the right thing for it to have: it makes `strategy :context` work out of the box for people who want
one file per tenant and nothing else. AshCell's binder does much of the same heavy lifting, and
differs in the choices it makes about **how the tenant split is configured** — which is the part
that cannot be pushed into a sensible default.

What remains open is not *whether* AshCell has its own binder, but how much of the fork's runtime it
sits on top of versus reimplements. That is the seam, and it is still to be drawn.

## Context

`ash_sqlite` commit `e04364b` ("improvement: manage tenant databases, so `strategy :context` works
out of the box") added `AshSqlite.Tenancy`: a supervisor with its own tenant registry, bind tracking,
connection supervisor, and manager — 1 065 lines across ten modules. It is, module for module, the
local half of AshCell's cell runtime:

| Fork | AshCell | Same job |
|---|---|---|
| `AshSqlite.Tenancy.Connection` | `AshCell.Cell` | one tenant's database, owned by one process, holding a repo instance for its lifetime |
| `AshSqlite.Tenancy.Manager` | `AshCell.Manager` | activation, residency bound, quarantine, seal |
| `AshSqlite.Tenancy.Registry` | `AshCell.Registry` | `via` tuples keyed by tenant |
| `AshSqlite.Tenancy.Database.encode/1` | `AshCell.CellKey.encode/1` | reversible escaping so two tenants cannot name one file |
| `AshSqlite.Tenancy.Binder` | `AshCell.Binder` | the `AshSqlite.TenantBinder` implementation |
| `AshSqlite.Tenancy.Migrations` | `AshCell.Migrator` | per-tenant migration on activation |
| `AshSqlite.Tenancy.UnavailableError` | `AshCell.CellUnavailableError` | a tenant that cannot be served |
| `AshSqlite.Transformers.CarryTenant` | `AshCell.Resource.Changes.CarryTenant` | routing the tenant to `transaction/4` |

This is deliberate, not accidental: the fork is growing a database-per-tenant engine on purpose,
and much of what AshCell learned belongs there. The duplication is therefore a question of where a
seam falls, not a mistake to be undone — and the two share their reasoning as well as their shape. The fork's
`Database.encode/1` carries the same injectivity argument as
[ADR-07](ADR-07-opaque-cell-keys.md), and its `Manager` has both `quarantined` and `sealed?`,
which are AshCell concepts that exist *because of* [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md)
and the drain path. **The fork has acquired the mechanisms without the object store that motivates
them.**

The forcing function is not aesthetic. `AshSqlite.DataLayer.Info.tenant_binder/1` now **defaults to
`AshSqlite.Tenancy.Binder` for any `strategy :context` resource**, so a resource that previously ran
unbound now routes into the fork's tenancy layer. In `ash_cell`'s own suite that layer is never
started, and 40 of 244 tests fail with `unknown registry: AshCell.TestRepo.TenantRegistry`. The
suite is red today, and it will stay red until this is decided.

## Options considered

### Option A — AshCell adopts the fork's tenancy layer wholesale, using the default binder

Delete `AshCell.Cell`, `AshCell.Manager`, `AshCell.Registry`, `AshCell.CellKey`, and
`AshCell.Migrator`; keep leases, fencing, replication, drain, holders, and the read cache on top of
`AshSqlite.Tenancy`.

*Buys:* around 700 lines of duplicated runtime deleted, one activation path instead of two, and
AshCell becomes unambiguously "the distributed half" — which is a clearer story than it has now.

*Costs, and the first is decisive:* the fork's `Manager` evicts on `max_resident` **with no
knowledge of a lease or a pending shipment**. [ADR-09](ADR-09-snapshot-before-releasing-the-lease.md)
requires a snapshot to reach the object store before a cell's lease is released; an eviction that
does not consult AshCell breaks that invariant silently, which is the exact class of bug
[ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md) was written to close. Also lost: holders
([ADR-17](ADR-17-bind-per-liveview-callback.md)) and the read cache's epoch bracketing
([ADR-13](ADR-13-pool-size-one-and-cache.md)), both of which hook the activation and binding paths
AshCell would no longer own.

### Option B — AshCell keeps its own binder and its own runtime (chosen for now)

`AshCell.Resource` already sets `tenant_binder AshCell.Binder`, so tenanted resources never reach
the fork's default. The remaining work is naming the binder on the resources that do not use the
extension.

*Buys:* the smallest change that makes the suite green, and it preserves every invariant AshCell has
evidence for. The fork's engine stays free to be the out-of-the-box answer without having to grow
AshCell-shaped hooks.

*Costs:* two implementations of the same local mechanics — file naming, activation, residency,
quarantine — drifting independently. Two `encode/1`s with the same injectivity argument is the
sharpest instance: if they ever disagree, one cell key maps to two files.

### Option C — split the seam (the likely end state)

The fork owns what is local and generic: file naming, opening a connection, migrating it, the
registry, and the `TenantBinder` default for people who want database-per-tenant with no AshCell.
AshCell owns what only makes sense with an object store: leases, generations, txid fencing,
replication, drain and handoff, holders, and the read cache — and supplies its own binder and its
own residency policy, which the fork's manager must defer to rather than override.

*Buys:* the duplication resolves in the direction that makes the fork genuinely useful upstream —
"database-per-tenant SQLite in Ash" without needing AshCell at all — while AshCell keeps every
invariant it has evidence for. It also matches [ADR-19](ADR-19-the-cell-cut-is-a-choice.md) more
closely than it first appears: the fork keys tenancy by the tenant string, and ADR-19 already says
the application encodes the cut *into* the tenant value, so `"acme:2026-08"` needs no new concept on
either side.

*Costs:* it needs an extension point in the fork's `Manager` that does not exist — something like
"ask this module before evicting" — and inventing extension points for one consumer is how a narrow
fork stops being narrow. It is also the most work of the three, and the seam has to be got right
once rather than discovered.

### Option D — hold the fork before `e04364b`

*Buys:* the suite goes green immediately with no design work.

*Costs:* it abandons work that is plainly the right direction for the fork, and defers rather than
answers the question. Listed because it is the cheapest way to unblock a demo deadline, not because
it is a real option.

## Decision and why

Option A is ruled out by one argument: **the invariants AshCell can prove are the ones tied to the
object store, and those are exactly the ones the fork's layer has no way to respect.** The fork's
manager can evict a tenant; only AshCell knows whether that tenant's snapshot has shipped and
whether releasing its lease is safe ([ADR-09](ADR-09-snapshot-before-releasing-the-lease.md)).
Relying on the default binder would put eviction on the wrong side of that line.

Between B and C, the deciding observation is **what the two layers actually differ on**. It is not
the plumbing — registries, connection processes and residency bounds are the same problem solved the
same way twice. It is the *split*: the fork keys tenancy by the tenant string, one file per tenant,
which is the right default and the only one a default can be. AshCell resolves a tenant to a **cell
key** first ([ADR-07](ADR-07-opaque-cell-keys.md), [ADR-19](ADR-19-the-cell-cut-is-a-choice.md)), so
a cut per entity, per time window (`"acme:2026-08"`), or per workload needs no code change. Two
tenants can share one cell, and one tenant can own many. Nothing in the fork's model expresses that,
and it should not have to.

So B is what ships now, because it is small and safe, and C is where this is heading, because once
the cell-key indirection is the only real difference there is little reason to carry a second
registry and connection process behind it. What decides *when* to move is whether the fork's manager
can defer eviction to an external policy — unverified, and named below.

This reasoning is judgement, not measurement. Nothing here was decided by a number.

## Consequences

- **What it rules out.** AshCell will not use the fork's default binder, so anything the fork adds
  *behind* that default — a smarter residency policy, a connection cache, per-tenant migration
  improvements — does not reach AshCell for free. Each has to be adopted deliberately. If C is
  later taken, the fork's eviction and quarantine paths become extensible, which is a larger
  surface than a data-layer option and weakens the "narrow and upstreamable" claim of
  [ADR-03](ADR-03-fork-ash-sqlite-narrowly.md).
- **What it makes worse.** Two layers with adjacent responsibilities and a seam between them is
  harder to explain than one layer, and "which of these two managers is running" becomes a question
  every new contributor asks. Option A would not have that problem.
- **What stays open.** Where the seam falls. Whether the fork's `Manager` can be given an eviction
  veto without acquiring AshCell-shaped concepts it should not know about. Whether the two
  `encode/1` implementations agree on every input — untested, and a disagreement means one cell key
  maps to two files. Whether the fork's `Connection` can hold a repo for a lease's lifetime rather
  than a residency window. Whether the cell-key indirection could itself be upstreamed as a
  configurable split, which would collapse the difference entirely.
- **What now depends on it.** All eight draft design docs (DD-05 through DD-12) assume AshCell owns
  activation and the transaction seam. Nothing in them should be implemented until this is settled,
  because a structure's tables are created by whichever layer migrates a cell.

## Evidence

- Fork commit `e04364b`, "improvement: manage tenant databases, so `strategy :context` works out of
  the box", read at `ash_sqlite` local checkout, version 0.2.17.
- The default that causes the breakage: `lib/data_layer/info.ex:29` and `:38` — `tenant_binder`
  "Defaults to `AshSqlite.Tenancy.Binder` for a resource with `strategy :context`".
- The overlap table above, from `lib/tenancy.ex:1-145`, `lib/tenancy/manager.ex:1-283`,
  `lib/tenancy/connection.ex:1-173`, `lib/tenancy/database.ex:1-124`, `lib/tenancy/binder.ex:1-20`.
- The failure: `mix test --exclude object_store` → 244 tests, 40 failures, every one
  `** (ArgumentError) unknown registry: AshCell.TestRepo.TenantRegistry` via
  `AshSqlite.Tenancy.with_tenant/3` ← `AshSqlite.Tenancy.connection_for/2` ←
  `AshSqlite.Tenancy.Registry.lookup/2`. Failing modules: `AshCellTest` (10), `AshCell.DrainTest`
  (8), `AshCell.ContextTest` (8), `AshCell.TransactionTest` (5), `AshCell.RegressionTest` (4),
  `AshCell.MigrationTest` (2), `AshCell.CloseReopenTest` (2), `AshCell.BinderTest` (1).
- The trigger in AshCell's own code: `test/support/multitenant_patient.ex` declares
  `strategy :context` with no `tenant_binder`, which now resolves to the fork's default.
- The fork's tenancy engine is intentional, ongoing work — stated by the author, who owns both
  repos. This ADR was first written treating it as an unexplained collision; that framing was
  wrong and is corrected here.
- **Not verified, and it is the assumption Option C rests on:** that the fork's `Manager` can defer
  eviction to an external policy at all. Nothing was read that says it can or cannot; establishing
  it means reading `lib/tenancy/manager.ex`'s eviction path and trying it. Until that is done,
  Option C is a preference rather than a plan.
- **Also not verified:** whether `AshSqlite.Tenancy.Database.encode/1` and
  `AshCell.CellKey.encode/1` are the same function. A differential property test over random binary
  keys would settle it, and should exist regardless of which option is taken.

## Notes

Elixir version is entangled with this: the workspace pinned 1.19.1, whose type checker crashes
compiling the fork's igniter-guarded `ash_sqlite.install` task, so `ash_cell/.tool-versions` now
pins `1.18.4-otp-27`. That is unrelated to the tenancy question but was found at the same time and
blocks the same suite.

Separately found while probing and worth its own issue: a SQLCipher key containing a hyphen fails
to open with `** (Exqlite.Error) near "-": syntax error`, because `PRAGMA key` is interpolated
unquoted. If a per-tenant key is ever derived from a cell key, an ordinary key like `"acme-eu"`
would fail to open its own database.
