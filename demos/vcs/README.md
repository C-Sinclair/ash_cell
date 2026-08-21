# vcs

A small version control system: a Rust CLI for the local half, an Elixir/Ash server for the
shared half, one encrypted SQLite cell per repository.

Not a Git clone and not Git-compatible. It reimplements the parts of Git's data model that are
worth keeping, in order to replace the part that is not — the server. See
[`docs/poc-plan.md`](docs/poc-plan.md) for the design and the deferred scope.

## What it proves, and where it stops

The cell cut here is **one cell per repository**, which is the closest of the demos to what a
durable object is actually for: a repository is long-lived, naturally single-writer, and its
one contended operation — moving a ref — is already serialised. Git protects that with
`refs/heads/main.lock`, a filesystem lock around an optimistic swap, with no transaction
covering the objects the swap depends on. Here the objects and the ref move in one
transaction inside one cell, so a push either lands whole or not at all.

It stops well short of Git. There is no branching beyond `main`, no merge, no diff, no
packfiles, no shallow or partial fetch, and `checkout` is really `reset --hard` (see below).
None of those are what the cell is being tested on.

The claims that are only checked end to end — a losing push refused, the repository being one
encrypted file with no plaintext in the WAL, a read never conjuring a cell, a lying client
rejected — live in [`scripts/e2e.sh`](scripts/e2e.sh), not in `mix test`, because they need
the real binary against a listening server.

## Layout

| Path | What |
|---|---|
| `cli/` | the `vcs` binary: objects, index, refs, status, push/fetch client |
| `lib/vcs/` | the server domain: cells, Ash resources, push, history |
| `lib/vcs_web/` | the JSON API |
| `scripts/e2e.sh` | a real server, the real binary, two clones, a losing push |

## The client

```bash
cd cli && cargo build --release

vcs init                                  # create .vcs/, HEAD -> refs/heads/main
vcs clone http://localhost:4000 me/proj   # init + fetch + checkout, into ./proj
vcs status                                # branch, staged, unstaged, untracked
vcs add README.md lib                     # files or directories; .vcs is never staged
vcs add gone.txt                          # a tracked path that is gone stages its deletion
vcs commit -m "first commit"              # snapshot the index, advance the branch
vcs log                                   # newest first
vcs show [<id>]                           # metadata and the snapshot's paths
vcs remote http://localhost:4000 me/proj  # point at a server
vcs push                                  # fast-forward only
vcs fetch                                 # objects and refs; does not touch the working tree
vcs checkout [<rev>] [--force]            # write a snapshot to disk; moves the branch with it
```

Ids are SHA-256 over `<kind> <len>\0<payload>`, shown abbreviated and resolvable by prefix.
Revisions also accept `HEAD`, a branch name, and a remote-tracking name such as `origin/main`.

`checkout` writes the files *and* moves the current branch, which makes it closer to
`git reset --hard`. With only one branch there is nothing to distinguish the two, and this is
the name people reach for; it needs splitting once branching exists.

## The server

Needs an `exqlite` compiled against SQLCipher — this failure mode is silent, so check it:

```bash
source .envrc          # EXQLITE_USE_SYSTEM and friends
mix deps.get
mix deps.compile exqlite --force
mix cipher.check       # must print a cipher version
mix run --no-halt      # listens on :4000
```

`PORT` and `VCS_CELL_DIR` override the port and the cell directory.

Configure `:vcs, :object_store` (endpoint, bucket, keys) to turn on replication. With it set,
`Vcs.Snapshotter` claims a lease per repository and ships changed repositories to the bucket
every `:snapshot_interval_ms` (default 60s); without it the fleet runs local-only and the
snapshotter does not start. `Vcs.Snapshotter.sweep/1` forces one now.

### API

```
GET  /api/repos/:owner/:name/refs        the branch tips
POST /api/repos/:owner/:name/missing     which of these object ids do you lack
POST /api/repos/:owner/:name/objects     here they are (ids verified against their bytes)
POST /api/repos/:owner/:name/push        move a ref, fast-forward only
POST /api/repos/:owner/:name/fetch       the closure of `want` minus `have`
```

Reads 404 rather than creating a repository; the push path creates one. No authentication —
a stated non-goal.

These have no client command. They exist because a repository that is a database can answer
them without a clone, and Git's server cannot answer them without walking every object:

```
GET /api/repos/:owner/:name/log
GET /api/repos/:owner/:name/history?path=lib/a.ex   commits that *changed* that path
GET /api/repos/:owner/:name/search?q=term           message search
GET /api/repos/:owner/:name/tree                    the current snapshot
```

## Tests

```bash
cd cli && cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test   # 24 tests
mix test                    # 17 tests
mix test --include minio    # +8 against a real object store
bash scripts/e2e.sh         # end to end, needs nothing running
```

The MinIO tests need a bucket:

```bash
minio server /tmp/ashcell-minio --address :9010   # MINIO_ROOT_USER=ashcell MINIO_ROOT_PASSWORD=ashcellsecret
mc alias set ashcell http://127.0.0.1:9010 ashcell ashcellsecret
mc mb ashcell/ashcell-test
```
