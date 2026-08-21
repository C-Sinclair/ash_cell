# CLAUDE.md — ash_cell

The library, plus the demos that prove it. This file covers working *inside this repo*. It is a
separate git repo from the workspace above it, so a clone of `ash_cell` alone sees this file and
not the workspace one — anything a contributor needs must be here or linked from here.

## Read the decisions before changing the design

**[`docs/decisions/`](docs/decisions) holds one ADR per architecture decision, and its
[README](docs/decisions/README.md) indexes them.** Read the relevant ones before proposing a
change to the cell runtime, the replication path, or the binding path.

This is not a formality. Five of those ADRs exist because something believed true was acted on
and then measured false — keying durability by lease generation, binding via a query-context pid,
widening the connection pool, logging a refused shipment instead of closing the cell, and the
compliance pitch. Each cost real time to find. An ADR is the cheapest way not to pay again.

- **Edit them in place.** An ADR states what is true now. When a decision changes, correct the
  file, set its **Status** to `reversed` if it went the other way, and note what changed on the
  **Last changed** line. Do not stack a successor ADR on top — git holds the history, and a SHA in
  the **Notes** section points at a specific earlier version.
- Start from [`docs/decisions/ADR-00-TEMPLATE.md`](docs/decisions/ADR-00-TEMPLATE.md).
- [ADR-20](docs/decisions/ADR-20-choose-a-durability-level.md) is **open**: `synchronous: :normal`
  means a returned `COMMIT` is not necessarily fsynced. Do not describe durability as settled.

## Where planning lives

| Kind | Where | Lifecycle |
|---|---|---|
| Decision | [`docs/decisions/`](docs/decisions) | edited in place; git carries the history |
| Design doc | [`docs/design/`](docs/design), or `demos/<name>/docs/design.md` | written before the work, updated during, frozen when it lands |
| The living design | [`docs/spec.md`](docs/spec.md) | edited in place; currently rev 2 |
| Simulation spec | [`docs/dst.md`](docs/dst.md) | edited in place |

A design doc's load-bearing sections are **what this proves**, **non-goals**, **measurements this
must produce**, and **where it stops**. Those four are what keep a claim from quietly widening
later; the template refuses to let you drop them. Naming the measurements *before* the work is
what stops a convenient subset being reported after it.

When starting a feature, write the design doc first and link the ADRs it rests on. When a decision
comes up *during* the work — an alternative rejected, an approach abandoned, a claim corrected —
that is an ADR, not a paragraph buried in the design doc.

## Conventions

- **Measure before claiming.** Every performance number in this repo comes from a run, with its
  shape stated (dataset, warm or cold, median of how many). An estimate must be labelled one.
- **Say where it stops.** Each demo README argues what it proves *and* where it stops. When a
  demo's behaviour changes, that README is part of the change.
- **Fork changes go upstream-shaped.** Changes needed in `ash_sqlite` are made in the sibling
  checkout as narrow commits matching that project's style, so each can become a PR. Both the
  `tenant_binder` and `transactions?` options default to current upstream behaviour for exactly
  this reason — see [ADR-03](docs/decisions/ADR-03-fork-ash-sqlite-narrowly.md).
- **Markdown links are checked.** `link_verifier` runs in CI and on every edit via a hook. Local
  links must resolve; relative links resolve from the file's own directory.
- Prefer answering a question with a small probe over building infrastructure for an answer we do
  not have yet. `scripts/` holds probes that earned their keep.

## Running things

The suite needs MinIO (`scripts/minio.sh`) — 24 tests run against a real object store and fail
loudly without one, because a mock of conditional-write semantics would only confirm our own
reading of them.

Every demo needs `exqlite` built against SQLCipher. A missing `EXQLITE_USE_SYSTEM` at
dep-compile time fails **silently**, yielding plain SQLite that cannot open an encrypted database;
`mix cipher.check` is the guard and it is not optional. See
[ADR-15](docs/decisions/ADR-15-sqlcipher-from-the-system-build.md).

Demos live in [`demos/`](demos) and each has its own README. They differ by where the cell is cut
— per tenant, per document, per user, per release channel, per repository — which is the point;
see [ADR-19](docs/decisions/ADR-19-the-cell-cut-is-a-choice.md). All of them run in CI.

## Claims to avoid

Recorded in full in [ADR-16](docs/decisions/ADR-16-isolation-is-blast-radius.md). In short: HIPAA
does not require physical isolation; BYOK here is not confidential computing, because the node
holds the plaintext key to serve; and cross-tenant analytics over snapshots re-comingles the data
the isolation pitch disclaims. Physical isolation is a blast-radius reduction and a sales
position, not a regulatory advantage.
