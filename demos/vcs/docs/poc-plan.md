# `vcs` — POC implementation plan

A small version-control system: a Rust CLI for the local half, an Elixir/Ash server for the
shared half. The point is not to reimplement Git. The point is to build the *smallest honest*
version of Git's data model, then replace its server side with an AshCell cell and see what
that changes.

## Thesis

Git's client side is a content-addressed store — elegant, and we copy it. Git's *server* side
is a directory of loose files plus `refs/heads/main.lock`: a filesystem lock protecting an
optimistic ref swap, with no transaction around the objects that swap depends on.

Here, **a repository is a durable object**. One repo is one encrypted SQLite cell, owned by
exactly one process at a time, fenced by a lease, snapshotted to an object store. Four
consequences we intend to demonstrate rather than assert:

| Unlock | Git today | Here |
|---|---|---|
| Serialised push | ref lock file + optimistic retry; objects land before the ref moves | one writer per repo; ref CAS inside the cell |
| Queryable history | full object walk; `log -- path` reads every commit | `SELECT` over a denormalised path index, no clone |
| Per-repo encryption | none; all repos share the disk | one SQLCipher file per repo, one key per repo; revoke = shred one repo |
| Point-in-time restore | filesystem backup of the whole forge | per-repo snapshot generation in S3, restore one repo |

## Layout

```
ash_cell/demos/vcs/
  cli/                 Rust workspace member — the `vcs` binary (lib + bin)
  lib/vcs*             Elixir: Ash domain, cells, Phoenix endpoint
  scripts/e2e.sh       the end-to-end proof: real binary, real server
  docs/poc-plan.md     this file
```

The CLI lives inside the demo rather than in a repo of its own, because the seam between the
two halves is a wire protocol and the only thing that proves it is `e2e.sh` driving both. Split
across two repos with no shared CI, the Elixir half would prove nothing the other demos don't.

The write-up lives outside this repo, in the workspace's `blog/`.

## Client: on-disk format

```
.vcs/
  HEAD                       {"ref":"refs/heads/main"}
  config.json                {"remote":"http://localhost:4000","repo":"conor/demo"}
  index.json                 staging area: path -> {blob, size}
  refs/heads/main            <commit-id>
  refs/remotes/origin/main   <commit-id>   (written by fetch)
  objects/<ab>/<rest>        one file per object, raw serialised bytes
```

Every write goes to a sibling temp file then `rename(2)`. `.vcs/` is never staged.

### Object model

Typed and length-prefixed, exactly like Git, because the framing is the interesting part:

```
<type> <byte-len>\0<payload>        type ∈ {blob, tree, commit}
id = SHA-256(that whole byte string)
```

The header is what makes the id commit to the *type* as well as the bytes, so a blob and a
tree with identical payloads cannot collide, and a truncated object is detectable.

- **blob** — payload is the file bytes verbatim.
- **tree** — payload is canonical JSON: a sorted array of `{path, blob}`. **Flat**, not
  nested: one tree per commit, holding every tracked path in full. Git nests trees so an
  unchanged subdirectory is one shared id; we deliberately don't, and the blog explains what
  that costs (a tree rewrite per commit, O(tracked files) not O(changed files)).
- **commit** — canonical JSON: `{tree, parent, message, timestamp, author}`. `parent` is
  `null` for the root commit. Canonical means keys in fixed order, no insignificant
  whitespace, so the id is stable.

**Why SHA-256:** BLAKE3 was the first choice — faster, 32 bytes, none of SHA-1's migration
history — and it was wrong, for a reason worth recording. The server must recompute every id
it is sent, because content addressing is only a guarantee if somebody checks. The server runs
on the BEAM, where SHA-256 is in `:crypto` and BLAKE3 is a Rust NIF (which did not build). A
hash both halves can compute from their standard library beats a marginally faster one only the
client has. Ids are shown as the first 12 hex chars and resolved by unique prefix.

## Commands

| Command | Semantics |
|---|---|
| `vcs init` | create `.vcs/`, `HEAD` → `refs/heads/main`, empty index. Fails if `.vcs/` exists. |
| `vcs clone <url> <repo> [dir]` | init, set the remote, fetch, adopt the remote branch, check it out. Refuses a non-empty target. |
| `vcs status` | branch, staged, modified-unstaged, untracked. Compares index against both HEAD's tree and the working tree by content hash (mtime/size only as a fast path). |
| `vcs add <paths...>` | hash file → write blob → record in index. Directories: **recursed**, deliberately, skipping `.vcs/`. A tracked path that is gone from disk stages its *deletion* (the way `git add` does); a path that was never tracked is still an error. Nothing is staged if any path fails. |
| `vcs commit -m <msg>` | build tree from index, write commit with HEAD as parent, advance the branch ref, clear the index. Refuses when the tree equals HEAD's tree unless `--allow-empty`. |
| `vcs log` | walk `parent` from HEAD, newest first: id, timestamp, message. |
| `vcs show [<id>]` | commit metadata plus the paths in its tree with blob ids and sizes. No diff. |
| `vcs remote <url> <repo>` | write `config.json`. Needed for push/fetch to have a target. |
| `vcs push` | send objects the server lacks, then ask it to move the ref from the id we believe it has to ours. Fast-forward only. |
| `vcs fetch` | ask for the server's refs, pull missing objects, write `refs/remotes/origin/*`. Does not touch the working tree or the local branch (no merge — that's a non-goal). |
| `vcs checkout [<rev>]` | write a snapshot to the working tree, set the index to it, and point the current branch at it. Refuses to destroy uncommitted work without `--force`. |

Revisions resolve as: `HEAD`, a branch name, a remote-tracking name (`origin/main`), a full id,
or a unique abbreviated id.

Timestamps: RFC3339 UTC, so `log` is readable and sorts lexically.

**On `checkout` doing two jobs.** It writes the files *and* moves the branch, which makes it
closer to `git reset --hard` than to `git checkout`. With no branching there is nothing to
distinguish the two operations, and `checkout` is the name a user reaches for. Once branching
exists the difference starts to matter and this needs splitting.

## Wire protocol

Plain JSON over HTTP, whole-object, blobs base64. Chatty and inefficient; trivially
`curl`-able, which is worth more in a POC and a blog post than bandwidth.

```
GET  /api/repos/:owner/:name/refs        -> {"refs":{"refs/heads/main":"<id>"}}
POST /api/repos/:owner/:name/objects     <- {"objects":[{"id","type","body_b64"}]}
     Returns which ids it already had, so the client sends only the rest.
POST /api/repos/:owner/:name/push        <- {"ref","expected","new"}
     409 with a clear non-fast-forward message when `expected` doesn't match.
POST /api/repos/:owner/:name/fetch       <- {"want":["<id>"],"have":["<id>"]}
     -> the transitive closure of want minus have.
```

Plus two endpoints that exist only to show the unlock, with no CLI equivalent in Git:

```
GET /api/repos/:owner/:name/history?path=lib/foo.ex   commits touching one path, as SQL
GET /api/repos/:owner/:name/search?q=...              message search, no clone
```

## Server: one cell per repo

`{AshCell, repo: Vcs.CellRepo, dir: ..., key_for: &Vcs.Vault.key_for/1, migrator: Vcs.Cells.Schema}`.
The tenant id is the repo's full name, `owner/name`. Resources use `AshCell.Resource` +
`multitenancy strategy :context`, so `Ash.read!(Vcs.Store.Commit, tenant: "conor/demo")` routes
itself; nothing inherits a binding.

Cell schema (versioned via `AshCell.Migrator`):

```sql
objects(id TEXT PRIMARY KEY, type TEXT, size INTEGER, body BLOB)
commits(id TEXT PRIMARY KEY, parent_id TEXT, tree_id TEXT,
        message TEXT, author TEXT, committed_at TEXT)
commit_paths(commit_id TEXT, path TEXT, blob_id TEXT)   -- denormalised on push
refs(name TEXT PRIMARY KEY, commit_id TEXT)
```

`commit_paths` is the whole queryable-history trick: it is the tree, flattened at write time,
so path history is an index scan instead of an object walk. Git could not keep this table
without giving up its immutable-object-directory model.

### Durability

`Vcs.Snapshotter` sweeps every resident repository on a timer: claim or renew that repository's
lease, and if its bytes have moved since the last sweep, ship the whole file to the object store
under `epoch * 1_000_000 + tick`. Composed rather than the raw lease generation because
`Replicator.snapshot/3` writes with `If-None-Match` — one write per generation, ever — and a
lease generation is stable for a whole ownership epoch. Composing keeps a single increasing
integer (which `latest_generation/2` requires: it parses the basename with `String.to_integer/1`)
while guaranteeing a successor's keys outrank every key its predecessor could reach.

This buys **snapshot fencing, not push exclusion**: writes are not gated on holding the lease,
so the guarantee is that two nodes cannot persist under the same generation, not that two nodes
cannot both accept a push. Gating writes on ownership belongs on the push path and is deferred.
Also not RPO=0 — a push is acked before it is snapshotted, so a crash loses up to one interval.

A global repo registry is **out of scope** — the repo name is the tenant id, and the cell is
created on first push. No Postgres, one data layer.

### Constraints this design respects

Taken as settled from the workspace CLAUDE.md, not re-derived:

- **AshSqlite has no transactions** (`can?(:transact) → false`). So push is not one atomic
  Ash action. It is: objects first (idempotent, content-addressed, safe to repeat), then a
  single-statement ref CAS. A crash between them leaves orphan objects, which are harmless
  and unreferenced — the same failure mode Git has, and worth saying out loud in the blog
  rather than papering over.
- **No aggregates.** Counts in the API come from reading and counting in Elixir, or raw SQL
  where it matters.
- Every entry point binds for itself; nothing relies on an inherited binding.

## Error handling

- `vcs-core` (the lib) returns `Result<T, VcsError>` with `thiserror`. Variants are
  user-facing situations, not `io::Error` passthroughs: `NotARepository`,
  `AlreadyInitialised`, `PathNotFound(PathBuf)`, `PathOutsideRepo`, `NothingStaged`,
  `EmptyCommit`, `UnknownRevision(String)`, `AmbiguousRevision`, `CorruptObject{id, why}`,
  `NoRemote`, `NonFastForward{..}`, `Server{status, message}`, plus `Io{path, source}` that
  always carries the path.
- `main` uses `anyhow`, prints `error: <chain>` to stderr, exits 1.
- No `unwrap`/`expect`/indexing on any user-controlled input path. `clippy -D warnings` is
  the gate.
- Path safety: every argument is canonicalised and checked to be inside the repo root, and
  rejected if it resolves into `.vcs/`.

## Test strategy

**Rust.** Unit tests beside the domain code for object framing, id stability, canonical JSON,
index/tree diffing, revision prefix resolution. Integration tests in `cli/tests/` drive the
built binary in a `tempfile::TempDir`, asserting on stdout and exit codes — including the full
flow the brief specifies (untracked → staged → committed → modified → committed → log → show
each snapshot) and every named failure case: outside a repo, nothing staged, double `init`,
missing `add` path.

**Elixir.** `ExUnit` against a temp cell dir: push creates a cell, re-push of the same objects
is idempotent, a stale `expected` is rejected as non-fast-forward, two concurrent pushes leave
exactly one winner, `history?path=` returns the right commits, a repo's file is unreadable
without its key, and a deleted cell restores from a MinIO snapshot.

**End to end.** A shell script starting the server, pushing from two clones, and showing the
loser's rejection. Not part of `cargo test` — MinIO and a running server are needed.

## Deferred, deliberately

Auth. Merge, rebase, cherry-pick. Multiple branches — `checkout` moves the one branch there is,
and there is no `branch` or `switch`. A separate `rm`: staging a deletion goes through `add`. Git object
compatibility. Packfiles, delta compression, GC. `.gitignore`. Partial staging. Symlinks, file
modes, submodules. Diff output. Concurrent access to one *working copy*. Nested trees. Shallow
or partial fetch. Anything that needs a global Postgres.
