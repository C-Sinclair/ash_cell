# ADR-15 — Get SQLCipher from the system build, and guard it with `mix cipher.check`

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · [ADR-16](ADR-16-isolation-is-blast-radius.md)

## The decision

Link SQLCipher via exqlite's existing `EXQLITE_USE_SYSTEM` support rather than forking exqlite.
Guard it with a mandatory `mix cipher.check` task, because the failure mode without it is
silent: a missing env var at dep-compile time yields a working plain SQLite build that cannot
open an encrypted database, and nothing else in the build says so.

## Context

Per-tenant encryption needs SQLCipher. exqlite has supported linking system SQLCipher since
0.9, via `EXQLITE_USE_SYSTEM`, so no fork is needed. `Exqlite.Connection.do_connect/1` sets the
key before any other statement — including `journal_mode` — satisfying SQLCipher's
key-before-anything requirement by construction. So per-tenant keys fall out of per-tenant
repos: `Repo.start_link(database: path, key: tenant_key)`.

The forcing problem is not linking SQLCipher — that is a one env var. It is that the failure
mode of *not* linking it is invisible: a build without the env var produces a normally-working
SQLite build, tests pass, the app runs, and only an attempt to open an already-encrypted file
fails, somewhere downstream and much later.

## Options considered

### Option A — no guard, rely on the env var being documented

Costs nothing to build. Rejected: the failure is silent by construction — a missing env var at
dep-compile time yields a working plain SQLite that simply cannot open an encrypted database.
Nobody is told, and the first symptom looks like a corrupt-database or crypto bug rather than a
missing build flag.

### Option B — `mix cipher.check`, asserting `PRAGMA cipher_version` is non-empty (chosen)

Turns a silent, deferred failure into an immediate, explicit one at build time. Must use a
prepared statement (fixed in `3323182`) to actually exercise the check correctly. Costs a
dedicated CI job: precompiled NIFs are disabled once system linking is used, so every build
environment needs a C toolchain and SQLCipher headers, and the cipher check needs its own job
with no shared cache, because what is being checked is what exqlite linked against *at compile
time*. A cached build from the plain-SQLite job would answer the wrong question.

## Decision and why

Option B was chosen because the cost of Option A is not hygiene — it is a data-confidentiality
failure that gives no signal at any layer until something tries to open an already-encrypted
cell and fails. "The failure mode is the reason this is an ADR." `mix cipher.check` converts
that failure from silent-and-late to explicit-and-immediate, at the cost of one dedicated
mix task and one dedicated CI job.

`mix cipher.check` lives as an alias in `ash_cell`'s own `mix.exs`, not as a shared task, so
demos duplicate it deliberately — a fast, clear build-level failure beats a confusing
downstream test failure that reads like a crypto bug.

## Consequences

- **What it rules out.** Precompiled exqlite NIFs — system linking requires a C toolchain and
  SQLCipher headers in every build environment.
- **What it makes worse.** CI now needs a dedicated job for the cipher check with no shared
  cache, because a cached build from the plain-SQLite job would answer the wrong question about
  what exqlite linked against at compile time.
- **What stays open.** Nothing about the linking approach itself; two further traps were found
  and fixed rather than left open (below).
- **What now depends on it.** Every demo's build depends on `mix cipher.check` running as its
  own CI job before tests that assume encryption is active.

Two further traps were found in practice and fixed, not merely noted:

- A randomly-minted per-boot key leaves existing encrypted cells unopenable after restart. Keys
  must be derivable.
- exqlite interpolates the key straight into `PRAGMA key = ...`, so it must arrive as a quoted
  SQL literal (`"x'<hex>'"`), not a raw string.
- A demo bug where `key_for/1` returned `nil` silently opened a **plaintext** database. Fixed to
  refuse rather than degrade.

## Evidence

- `Exqlite.Connection.do_connect/1` sets the key before any other statement, including
  `journal_mode`.
- `mix cipher.check` asserts `PRAGMA cipher_version` is non-empty, via a prepared statement
  (fixed in `3323182`).
- Commits: `3323182`, `01e2bbd`.
- Not verified here: throughput cost of system-linked SQLCipher versus precompiled plain
  SQLite NIFs.

## Notes

See [ADR-16](ADR-16-isolation-is-blast-radius.md) for what per-tenant encryption does and does
not buy — in particular, that the node holding the plaintext key to serve means this is not
confidential computing.
