# AshCell demos

Each subdirectory is a standalone Phoenix application that proves something specific about
cells. They are separate apps on purpose: each one has to be runnable on its own, with its
own README, so a claim can be checked without standing up the whole rig for every other
claim.

| Demo | Cell cut | What it proves |
|---|---|---|
| [`console/`](console) | one cell per **tenant** (a clinic) | The core pitch: physical isolation, encryption at rest, single-writer ownership, object-store durability, N+1 immunity, and the deploy path — measured against Postgres on the same query. |
| [`collab_editor/`](collab_editor) | one cell per **record** (a document) | That the cell boundary is a choice, not the tenant. A Lexical + Yjs collaborative editor where the CRDT handles convergence and the cell handles the thing a CRDT does not: safely collapsing an append-only update log into a snapshot. Verified in two real browsers. |
| [`shroud/`](shroud) | one cell per **user**, plus a global Postgres | That a cell can hold data the *server* cannot read. Passkey-derived keys (WebAuthn PRF) that never leave the browser, per-audience sharing that works while the owner is offline, and account deletion by destroying key material rather than data. Measured the pull-model feed: 200 cells in 16.6 ms — and the 8.9x cliff when `max_resident` is undersized. |
| [`rollout/`](rollout) | one cell per **release channel** | That the read/write ratio can be extreme in the other direction: a pointer written twice a week and read by every device on every check-in, with content-addressed blobs in the object store. |
| [`branch/`](branch) | one cell per **branch** | That a cell's snapshot history is a timeline you can cut from. A branching SQLite service — provision, snapshot, branch at a txid, diverge, promote — where promotion is a fast-forward or a refusal, because two diverged SQLite databases have no correct automatic merge. |
| [`relay/`](relay) | one cell per **stream** | That an offset can outlive the process that issued it. A resumable token stream where a reader reconnects after the generator is killed, the cell is closed, and its file is deleted — served from offset-keyed segments in the object store, stitched onto the cell, then onto live fan-out. |
| [`vcs/`](vcs) | one cell per **repository** | That a cell fits a genuinely single-writer domain. A small version control system — Rust CLI, Ash server — where objects and the ref move in one transaction, so Git's `main.lock` and its optimistic retry are not needed. The losing push is refused, not reconciled. |

They all depend on the library and the fork by relative path:

```elixir
{:ash_sqlite, path: "../../../ash_sqlite", override: true},
{:ash_cell, path: "../.."}
```

so an edit in either is picked up on the next `mix compile` with no publishing step.

## Shared prerequisites

Every demo needs an `exqlite` built against SQLCipher, which is an environment concern, not
a dependency one:

```bash
source .envrc                                 # in the demo directory
mix deps.compile exqlite --force
```

A missing `EXQLITE_USE_SYSTEM` at dep-compile time fails *silently* — you get a working
SQLite with no encryption. `mix cipher.check` in `ash_cell` is the guard; run it after any
dependency rebuild.

Demos that use the object store need MinIO; each README says so and gives the commands.
`branch/` is the one that **cannot run without it** — a branch is a copy of a snapshot, and
snapshots live in the bucket. `relay/` is close behind: with no bucket there are no segments, so a
resume can only ever be served from the cell, which is the half that was already easy.

`vcs/` additionally needs a Rust toolchain, because its client half is the `vcs` binary. Its
end-to-end proof (`vcs/scripts/e2e.sh`) drives that binary against a listening server, so it is
a script somebody runs on purpose rather than part of `mix test`.
