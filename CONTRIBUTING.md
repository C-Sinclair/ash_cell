# Contributing to AshCell

Bug reports, questions and pull requests are all welcome. AshCell is
experimental and pre-1.0, so the most useful contribution is usually a case where
it does the wrong thing.

## Getting set up

You need a running MinIO and, for anything touching encryption, a SQLCipher build
of `exqlite`.

```bash
mix deps.get
scripts/minio.sh    # starts MinIO, creates the test bucket, waits for it
mix test
```

`scripts/minio.sh --wait` waits on an instance you already started. Credentials
and ports live in `config/config.exs` and the script, in that order — change them
in one place.

**MinIO is a build dependency, not a convenience.** Seventeen tests fail loudly
without a reachable store rather than skipping. The whole ownership design rests
on S3 conditional-write semantics, so a mocked store would only ever confirm our
own reading of them.

For the encryption paths:

```bash
brew install sqlcipher
export EXQLITE_USE_SYSTEM=1
export EXQLITE_SYSTEM_CFLAGS=-I$(brew --prefix sqlcipher)/include/sqlcipher
export EXQLITE_SYSTEM_LDFLAGS="-L$(brew --prefix sqlcipher)/lib -lsqlcipher"
mix deps.compile exqlite --force
mix cipher.check
```

A missing `EXQLITE_USE_SYSTEM` at dep-compile time fails **silently** — you get
plain SQLite that cannot open an encrypted database. `mix cipher.check` is the
only thing that catches it. Run it after any dependency rebuild.

## The fork

AshCell depends on a [fork of `ash_sqlite`](https://github.com/C-Sinclair/ash_sqlite),
resolved from a sibling checkout when there is one and from git otherwise. The
usual layout is two checkouts side by side:

```
ashcell/
  ash_cell/
  ash_sqlite/
```

With that in place, edits to the fork are picked up on the next compile.

**Keep fork changes upstreamable.** Narrow commits, matching that project's
existing style, so each can become a PR. Everything AshCell needs from the fork
(`tenant_binder`, `transactions?`, `transaction/4`) is behind an option that
defaults to upstream behaviour, and it should stay that way.

## Before opening a pull request

Run what CI runs:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Warnings are errors in CI and not locally, so a warning introduced in a refactor
cannot ride along unnoticed in a green run.

If your change touches the library's public surface, the demos compile against
the working tree in CI and will fail there — build them locally rather than
finding out on the PR:

```bash
cd demos/console && mix compile --warnings-as-errors
```

## How the library is structured

- `lib/ash_cell.ex` — the public API and the fleet supervisor
- `lib/ash_cell/manager.ex`, `cell.ex`, `registry.ex` — residency: which cells are
  open, which process owns each, and the LRU bound
- `lib/ash_cell/cell_key.ex` — where Ash's tenant becomes a cell key, and a cell
  key becomes a filename
- `lib/ash_cell/binder.ex` — what the fork's `tenant_binder` calls, once per
  statement
- `lib/ash_cell/resource.ex` and `resource/` — the Spark extension: transformer,
  verifier, and the change that carries the tenant into the transaction callback
- `lib/ash_cell/lease.ex`, `replicator.ex`, `object_store.ex`, `ownership.ex` —
  durability and single-writer enforcement
- `lib/ash_cell/migrator.ex` — per-cell schema versioning against `PRAGMA
  user_version`

## Expectations for changes

**Measure before claiming.** Every performance number in the docs comes from a
run, not an estimate. If you change something that a published number describes,
re-run it and update the number, or delete the claim.

**Test against real files and a real store, not mocks.** The suite reads cell
files directly with `sqlite3`, deletes databases and restores them from the
bucket, and races twelve concurrent claimants for one cell. That is deliberate:
the interesting failures are the ones a mock agrees with you about.

**Cell names in tests must carry wall-clock time.** Use
`AshCell.ObjectStoreCase.unique_cell/1`. `System.unique_integer/1` restarts from
small numbers each VM run while the bucket outlives every run, so a name built
from it alone inherits a previous run's lease and snapshots — and whether a test
passes depends on what ran before it.

**A behaviour change is a documentation change.** Depending on what moved:

- `usage-rules.md` — what LLM coding agents read. Public API and its hazards.
- `README.md` — including the "What's proven, and what isn't" table, which is a
  claim about the test suite and must stay true of it.
- `docs/spec.md` — the design and the verified constraints.
- `demos/<name>/README.md` — each argues what its demo proves *and where it
  stops*. When a demo's behaviour changes, its README is part of the change.
- `CHANGELOG.md`, under `## [Unreleased]`.

**Do not soften the limits.** The README and the usage rules state what AshCell
does not do — ~1s RPO rather than zero, no aggregates, fencing that protects
writes and not reads, HIPAA not requiring physical isolation. Those sections exist
because earlier drafts overstated the case. Adding a caveat is welcome; removing
one needs the work that makes it false.

## Releases

AshCell is **not on Hex yet**, and cannot be until the fork's changes land
upstream: Hex refuses a package with a git dependency. The package metadata in
`mix.exs` is in place for when that resolves.

When it does, releases will work as:

1. Move the `## [Unreleased]` entries under a new version heading
2. Bump `@version` in `mix.exs`
3. Commit, then tag: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push --follow-tags`

Pushing the tag publishes via `.github/workflows/release.yml`, which refuses to
publish if the tag and `mix.exs` disagree.

Breaking changes go out in a minor version bump while pre-1.0, called out in the
changelog with what to change.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By participating
you are expected to uphold it.
