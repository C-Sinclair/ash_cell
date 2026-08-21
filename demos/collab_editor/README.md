# Collaborative editor — one cell per *document*

A rich text editor several people type in at once: [Lexical](https://lexical.dev) (Meta's
editor framework) and [Yjs](https://yjs.dev) in the browser, one AshCell cell per document on
the server.

The console demo proves cells work when a cell is a customer. This one exists to prove the
cell boundary is a **choice** — here it is a single record — and to be honest about which
part of real-time collaboration a cell actually solves.

## The claim

> A CRDT gives you convergence. It does not give you a safe place to keep the log.
> **The cell does.**

Yjs does the merging, and it does it properly: two people typing inside the same word
converge character by character and nobody loses a keystroke. That is not the cell's doing,
and this README does not pretend otherwise. The server stores opaque Yjs updates and relays
them.

The cell earns its place at the operation the CRDT leaves unsolved. A Yjs update log grows
forever, so it has to be collapsed into a snapshot and truncated — and **compaction is a
read-modify-write over the whole log**:

```elixir
AshCell.transaction(doc_id, fn ->
  head    = head_seq(doc_id)        # read the log
  state   = merged_state(doc_id)    # merge it (y_ex, a Rust NIF over yrs)
  put_snapshot(state, head)         # write the snapshot
  delete_updates_through(head)      # truncate what was merged
end)
```

Two nodes doing that concurrently can each merge a log the other is truncating, and an update
that lands between one node's read and its delete is **gone** — a corruption the CRDT cannot
repair, because the update no longer exists anywhere. Anyone building this on shared storage
needs a lock, a lease, or a designated compactor process.

A cell is all three, by construction:

| Property | Where it comes from |
|---|---|
| Compaction cannot interleave with an append | one connection per document (`pool_size: 1`) |
| The merge-and-truncate takes its write lock up front | `AshCell.transaction/2` opens `BEGIN IMMEDIATE` |
| A second node cannot be compacting the same document at all | the lease, enforced by conditional writes on the object store |
| A cell taken mid-compaction aborts rather than leaving a truncated log with no snapshot | one transaction, and `AshCell`'s drain path |

`test/collab_editor/editing_test.exs` runs 15 concurrent appends against 4 concurrent
compactions on one document and asserts every single update survives.

## What else it proves

| Claim | Where to look |
|---|---|
| **The cell key is a policy, not an identity.** A document id becomes the cell `doc:<uuid>`, on disk as `doc~3A<uuid>.db`. The `:` never reaches the filesystem and the encoding is reversible, so two keys can never share a file. | `lib/collab_editor/cell_key.ex`, and `ls priv/cells` |
| **Isolation is physical at record granularity.** One document's entire edit history is in one file. There is no `document_id` column anywhere, because there is nothing to scope. | `lib/collab_editor/cells/schema.ex` |
| **Every document has its own encryption key**, covering its whole history rather than just current state. Shredding one key leaves those bytes on disk permanently unreadable and touches no other document. | `lib/collab_editor/cells/vault.ex`, `encryption_test.exs` |
| **Deleting a document is `rm`.** No dead tuples still holding the text of something somebody asked you to delete. | `Editing.delete_document/1` |
| **Updates are durable before they are visible.** An update is stored, then broadcast — so a node dying between the two loses nothing anyone has seen. | `Editing.append/3` |
| **A reconnect resumes exactly**, on a monotonic `seq` the cell assigns. The CRDT does not need an order to converge, but an order makes an incremental resume answerable without exchanging state vectors — and when compaction has absorbed what a client missed, it is told to take the snapshot rather than handed a short tail. | `Editing.updates_since/2`, `editor_live_test.exs` |
| **Awareness is relayed and never stored.** Cursors are worthless a second after they are produced; spending the cell's single connection on them would compete with the edits that matter. | `lib/collab_editor_web/presence.ex`, `Editing.relay_awareness/3` |
| **A transaction cannot span two documents,** and says so rather than committing half. | `editing_test.exs` |
| **One unreadable cell does not take out the fan-out.** The document list degrades to "cell unreadable" for that row — the per-cell failure mode stays single-tenant only if callers handle it. | `Editing.stats/1` |

### Verified in real browsers

The claim that matters here cannot be tested from Elixir. `test/browser/convergence.mjs`
drives two headless Chromium tabs typing 30 characters each into the *same paragraph
simultaneously*, and asserts:

```
ok   both tabs converge on the same text — 60 chars
ok   no keystrokes lost — 30 a + 30 b of 30 each
ok   no javascript errors
ok   the other caret is rendered — {"attached":true,"carets":1,"peers":2}
ok   compaction merged the log — Merged 63 updates
ok   the log was outstanding beforehand
ok   editing still propagates after compaction
ok   a fresh tab loads the compacted document — 66 chars
ok   no errors on the fresh tab
```

That test decided the design. An earlier version of this demo synced whole blocks with
last-writer-wins resolution; it passed every Elixir test and still lost keystrokes here,
because the failure only exists once two real editors are typing at once.

## What it does not prove

- **The cell is not what makes editing correct.** Yjs is. Swap the cell for Postgres and the
  editor still converges; what you lose is safe compaction, one owner per document, physical
  isolation, and per-document crypto-shredding.
- **Not RPO=0.** Path A: local fsync plus ~1s async shipping, same as the console demo.
- **Reads are bounded, not fenced.** A partitioned node refuses to serve past the lease TTL,
  which is the one place clock skew matters.
- **Listing documents is a fan-out**, opening every cell to read one row. Fine at demo
  scale, a real problem at ten thousand documents, and the reason a separate index exists in
  production. Left as a fan-out here so the cost is visible in the code rather than
  discovered later.
- **A deploy migrates one cell per document.** Cutting cells this fine multiplies the cell
  count that the fleet-wide unsolved problems scale with — see `ash_cell/docs/spec.md` §4.6.
- **No compaction policy.** Compaction is a button, because the demo is about whether it is
  *safe*, not when to run it. In production it belongs on a size or age threshold.

## Why a document is a defensible cell

A cell is a heavy object to hand to a record: a serialising writer, an encrypted file, a
snapshot lineage, a lease. The test for whether it is worth it is whether the things a cell
*refuses* are things this object wanted.

A document is edited by a handful of people at once, needs its history kept somewhere
bounded, and never needs a transaction or a join with another document. Cross-cell
transactions and cross-cell queries are exactly what a cell refuses. Nothing is given up
that a document wanted.

Chat rooms, agent sessions, game matches, and spreadsheets pass the same test. Customers'
invoices do not.

## The protocol

Two kinds of bytes go over the LiveView channel:

- **Updates** — opaque Yjs updates, one per burst of local changes. Stored in the cell's
  `updates` table with a `seq`, then broadcast to the other clients on that document.
  Persisted.
- **Awareness** — cursors, selections, names. Relayed to the other clients and stored
  nowhere.

The server merges rather than relays blindly: `y_ex` (a Rust NIF over `yrs`) means Elixir can
actually combine updates, which is what makes compaction — and therefore the whole argument —
possible. Without a real Yjs implementation on the server you could store updates but never
collapse them.

`assets/js/lexical_hook.js` wires `@lexical/yjs` by hand, because the ready-made
`CollaborationPlugin` is React-only. The provider it expects is a small shim over the
LiveView channel; the transport is `pushEvent`.

## Layout

| Path | Role |
|---|---|
| `lib/collab_editor/cell_key.ex` | The cut: tenant → `doc:<uuid>`. Also the argument for and against cutting this fine. |
| `lib/collab_editor/cells/schema.ex` | Three tables per document: `document`, `updates`, `snapshots`. |
| `lib/collab_editor/cells/vault.ex` | Per-document keys, derived not minted. |
| `lib/collab_editor/docs/resources.ex` | The Ash resources, all `strategy :context` on `AshCell.Resource`. |
| `lib/collab_editor/editing.ex` | The protocol, and `compact/1` — the operation the cell exists for. |
| `lib/collab_editor_web/live/editor_live.ex` | The editor LiveView: binding per callback, holding the cell, relaying. |
| `lib/collab_editor_web/live/index_live.ex` | The document list, as a fan-out over cells. |
| `assets/js/lexical_hook.js` | Lexical + Yjs, bound by hand, with a LiveView-channel provider. |
| `test/browser/convergence.mjs` | The two-browser test that decided the design. |

## Running it

Needs an `exqlite` built against SQLCipher, and Node. No Postgres. MinIO only for snapshots.
`y_ex` downloads a precompiled NIF, so there is no Rust toolchain to install.

```bash
source .envrc                       # EXQLITE_USE_SYSTEM and the SQLCipher paths
mix deps.compile exqlite --force    # a missing env var here fails *silently*
mix setup                           # deps, npm install, assets
mix phx.server
```

Open http://localhost:4000, create a document, then open it in a second window. Type in both
at once, in the same word — nothing is lost, and you can watch the other caret move. The
sidebar shows the update log growing; **Compact the log** collapses it into a snapshot and
reports what it merged, while both editors keep typing.

```bash
mix test          # 28 tests: compaction safety, isolation, encryption, the wire path
mix browser.test  # 9 checks in two real Chromium tabs (needs the server running)
```

For poking at it live, the hook is on `window.__collab`: `__collab.doc`,
`__collab.awareness.getStates()`.
