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

All three depend on the library and the fork by relative path:

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
