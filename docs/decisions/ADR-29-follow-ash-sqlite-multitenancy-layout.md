# ADR-29 — Configure and start cells the way `AshSqlite.MultiTenancy` configures and starts tenants

**Status:** accepted
**Date:** 2026-10-19
**Deciders:** Conor Sinclair
**Relates to:** [ADR-03](ADR-03-fork-ash-sqlite-narrowly.md) · [ADR-07](ADR-07-opaque-cell-keys.md) · [ADR-15](ADR-15-sqlcipher-from-the-system-build.md) · [ADR-22](ADR-22-where-the-tenancy-runtime-lives.md) · `lib/ash_cell/repo.ex` · `lib/ash_cell/cell.ex`

## The decision

Where `AshSqlite.MultiTenancy` (ash_sqlite PR #246) and AshCell answer the same question, answer it
the way AshSqlite does. Three answers change now:

- A cell repo's `child_spec/1` starts the cell fleet. Its options sit under the repo's `tenants:`
  key, in the application env or as the child's option, and `{MyApp.CellRepo, tenants: [...]}` is
  the documented entry point. `{AshCell, repo: ..., ...}` still works.
- Each cell's repo instance is started with `tenant:` set to its cell key, so the repo's `init/2`
  configures one cell differently from another.
- A cell's SQLCipher key comes from that `init/2`. The `:key_for` fleet option is deleted.
  `encrypted?: true` keeps the refusal of a cell with no key, checked in `AshCell.Repo`'s own
  `init/2`.

Cell file names already follow AshSqlite's encoding ([ADR-07](ADR-07-opaque-cell-keys.md)).
Migrations stay on `AshCell.Migrator` until PR #246 merges.

## Context

AshCell now depends on upstream `ash_sqlite` ([ADR-03](ADR-03-fork-ash-sqlite-narrowly.md)), and PR
#246 proposes a database-per-tenant runtime for it. The two do the same local work: open one file
per tenant, migrate it, and own its repo instance. They differ in what AshCell adds on top: leases,
replication, drain, eviction and the read cache ([ADR-22](ADR-22-where-the-tenancy-runtime-lives.md)).
Every place where they also differ in configuration is a place where an application moving between
them has to rewrite code, and where AshCell would have to translate if it ever delegated to
AshSqlite's runtime.

## Options considered

### Option A — keep AshCell's own configuration

`{AshCell, repo: ..., key_for: ...}`, and a key callback taking a cell key. Costs nothing now. Every
later move toward AshSqlite then carries a configuration migration with it, and the two libraries
keep two vocabularies for one idea.

### Option B — wait for PR #246 to merge, then align

Avoids aligning to a shape that changes in review. Costs the time in between: new code written
against AshCell's configuration has to move later. The probe in
`scripts/tenant_supervisor_probe.exs` may itself change the PR's resolver, but not its
configuration keys or its `init/2` contract.

### Option C — align the configuration and `init/2` now, migrations after the merge (chosen)

The configuration key (`tenants:`), the entry point (the repo in the supervision tree), and the
per-tenant `init/2` contract are the parts of the PR least likely to change, because they are its
public interface. Migrations are the exception. Moving from `AshCell.Migrator`, which records its
progress in `PRAGMA user_version`, to `Ecto.Migrator`'s files, which record theirs in
`schema_migrations`, changes what every existing cell has on disk. That waits until the format it
moves to is merged.

## Decision and why

Option C, because following AshSqlite wherever the two overlap is the direction this project has
taken since [ADR-03](ADR-03-fork-ash-sqlite-narrowly.md) was reversed, and because the configuration
is cheap to move while the migration format is not. The reasoning is judgement,
not measurement.

The key check moved with the key. `AshCell.Cell` used to receive the key from `:key_for` and refuse
`nil` itself. The key is now computed inside the repo's `init/2`, which `AshCell.Cell` cannot see,
so the check runs at the end of the `init/2` chain, in `AshCell.Repo.check_init/2`. That is where
the final configuration exists.

## Consequences

- **What it rules out.** A key function that takes anything but the cell key, or that runs
  outside the repo. Anything that needs the key has to go through `init/2`.
- **What it makes worse.** The no-key check depends on an `init/2` override calling `super/2`
  after setting `:key`. An override that returns `{:ok, config}` itself skips the check, and with
  it AshSqlite's own `init/2`. The error for a missing key is now an `ArgumentError` raised while
  the repo starts, which reaches `AshCell.Manager.quarantined/0` wrapped in a tuple, where it used
  to be the atom `:no_key`.
- **What it exposes.** Ecto's `config/0` runs `init/2` too, with no `:tenant`. AshCell used to
  call `repo.config/0` to find the repo's telemetry prefix, and that asked the collab_editor
  demo's vault for the key of `nil`, which crashed the demo at boot. `AshCell.ReadCache` now
  works out the prefix as Ecto does without calling `init/2`, and `test/repo_test.exs` "starting
  the fleet runs init/2 only for cells" pins it. Application code that calls
  `MyApp.CellRepo.config/0` still runs `init/2` with no cell, so a key function has to answer
  `nil` for a `nil` tenant.
- **What stays open.** The fleet's processes are still named globally (`AshCell.Manager`,
  `AshCell.Registry`), not per repo as AshSqlite names its tenant supervisor. Two cell repos on
  one node are therefore not supported. Migrations are not aligned.
- **What now depends on it.** Every demo's `application.ex` and encrypted cell repo, and
  `test/repo_test.exs`.

## Evidence

- `test/repo_test.exs`: the fleet starts from `{TestRepo, tenants: [...]}` and from the
  application env; a cell repo with no `tenants:` refuses to start, naming the key; `init/2`
  receives the cell key as `:tenant`; and `init/2` drops `:tenant`, `:tenants` and `:encrypted?`
  before the adapter sees them.
- `test/regression_test.exs` `AshCell.KeyFailClosedTest`: a cell whose `init/2` sets no key in an
  `encrypted?: true` fleet refuses to start and leaves no file. Other cells are unaffected, and a
  fleet without `encrypted?` opens it.
- The shape followed is ash_sqlite PR #246 at `82c20bb`: `AshSqlite.MultiTenancy.Supervisor`'s
  `child_spec/3` and `AshSqlite.MultiTenancy.Tenant.handle_continue/2`, which starts the instance
  with `tenant:`.
