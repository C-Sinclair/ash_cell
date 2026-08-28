# Architecture decisions

One file per decision. **Read these before proposing a change to the cell runtime, the
replication path, or the binding path** — most of them record something that was tried and did
not work, or a claim that turned out false, and re-deriving those costs a day each.

**Edit these in place.** An ADR should say what is true now, so a reader never has to work out
which of two files is current. Git is the history — `git log -p docs/decisions/ADR-08-*.md` shows
what a decision used to say, and a SHA in an ADR's **Notes** section points at a specific earlier
version. Corrections are the point, not an embarrassment: five of these exist because something
believed true was measured false, and each says so in its own body rather than in a successor
file.

Start from [`ADR-00-TEMPLATE.md`](ADR-00-TEMPLATE.md). Design docs for planned or built features
live in [`../design/`](../design), and reference these.

## Binding — how a query reaches the right database

| # | Decision | Status |
|---|---|---|
| [01](ADR-01-bind-tenants-per-process.md) | Bind tenants per-process with `put_dynamic_repo/1`, not a query-context pid | corrects an earlier belief |
| [02](ADR-02-bind-in-the-data-layer.md) | Bind in the data layer via a `tenant_binder` seam, not action hooks | accepted |
| [03](ADR-03-fork-ash-sqlite-narrowly.md) | Fork `ash_sqlite` narrowly and keep it upstreamable; do not vendor it | accepted |
| [04](ADR-04-transactions-behind-an-opt-in-flag.md) | Enable transactions behind an opt-in flag, with `BEGIN IMMEDIATE` | accepted |
| [05](ADR-05-refuse-cross-cell-transactions.md) | Refuse cross-cell transactions rather than build a coordinator | accepted |
| [06](ADR-06-own-repo-for-shared-tables.md) | Give non-tenanted resources their own repo module | accepted |
| [07](ADR-07-opaque-cell-keys.md) | Key cells by an opaque cell key, and encode it injectively | accepted |

## Ownership and durability

| # | Decision | Status |
|---|---|---|
| [08](ADR-08-fence-by-shared-txid.md) | Fence durability by a shared txid namespace, not by lease generation | corrects an earlier belief |
| [09](ADR-09-snapshot-before-releasing-the-lease.md) | Snapshot before releasing the lease, and checkpoint before snapshotting | accepted |
| [10](ADR-10-fail-closed-on-a-refused-shipment.md) | Stop serving a cell once a shipment proves it is not ours | corrects an earlier belief |
| [11](ADR-11-simulate-the-protocol-only.md) | Simulate the coordination protocol only; SQLite and real processes stay out | accepted |
| [12](ADR-12-whole-file-snapshots-on-a-schedule.md) | Ship whole-file snapshots on a jittered schedule; defer per-commit durability | accepted |
| [14](ADR-14-bounded-read-staleness.md) | Bound read staleness on the monotonic clock, and expose it as explicit modes | accepted |
| [20](ADR-20-choose-a-durability-level.md) | Choose SQLite's durability level (`synchronous`) | **proposed — open** |
| [21](ADR-21-close-does-not-await-the-connection.md) | Close does not wait for the connection; the rewrite path asks it to | accepted |
| [22](ADR-22-where-the-tenancy-runtime-lives.md) | Keep AshCell's own tenant binder as the fork grows its own engine; the seam is the cell-key split | accepted — **seam open** |
| [23](ADR-23-merge-by-fast-forward-or-refuse.md) | Merge a branch only when its origin has not moved; refuse divergence rather than reconcile it, and measure divergence by content digest | accepted |
| [24](ADR-24-a-segment-set-is-not-a-disjoint-cover.md) | A stream reader de-duplicates by offset and does not trust the store's listing to be duplicate-free | corrects an earlier belief |

## Performance, encryption, integration

| # | Decision | Status |
|---|---|---|
| [13](ADR-13-pool-size-one-and-cache.md) | Keep `pool_size` at 1 and cache above SQLite instead | corrects an earlier belief |
| [15](ADR-15-sqlcipher-from-the-system-build.md) | Get SQLCipher from the system build, and guard it with `mix cipher.check` | accepted |
| [17](ADR-17-bind-per-liveview-callback.md) | Bind per LiveView callback, never at mount, and track holders explicitly | accepted |
| [18](ADR-18-tenant-in-job-args.md) | Carry the tenant in job args, and fail closed when it is missing | accepted |

## Claims and scope

| # | Decision | Status |
|---|---|---|
| [16](ADR-16-isolation-is-blast-radius.md) | Claim physical isolation as blast-radius reduction, not as compliance | corrects an earlier belief |
| [19](ADR-19-the-cell-cut-is-a-choice.md) | Treat the cell cut as a choice, with one cell per tenant as the default | accepted |
| [25](ADR-25-no-record-handoff-in-the-library.md) | Do not build record handoff into the library; publish the ordering and prove it with a probe | accepted |

## The five that correct something

These matter most, because each one records a belief that was held, acted on, and then measured
false. Do not reintroduce the superseded position:

- **[ADR-01](ADR-01-bind-tenants-per-process.md)** — the query-context override cannot carry a
  repo *instance*. It selects a module; a pid raises.
- **[ADR-08](ADR-08-fence-by-shared-txid.md)** — keying durability by lease generation does not
  fence at all. `AshCell.Lease`'s own moduledoc said otherwise and was wrong.
- **[ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md)** — a refused shipment used to log and
  carry on serving. It now quarantines and closes.
- **[ADR-13](ADR-13-pool-size-one-and-cache.md)** — widening the connection pool was claimed as a
  cheap win. Measured, it is flat on point reads and 1.9× *worse* on a realistic join.
- **[ADR-16](ADR-16-isolation-is-blast-radius.md)** — the compliance pitch was overstated. HIPAA
  does not require physical isolation.
- **[ADR-24](ADR-24-a-segment-set-is-not-a-disjoint-cover.md)** — a stream's segments were assumed
  to be a disjoint cover, so a read concatenated the tiers and nothing else. The store's listing
  returned one key twice under a concurrent write, and a resume came back with a duplicated offset.
- **[ADR-04](ADR-04-transactions-behind-an-opt-in-flag.md)** — `AshCell.Resource` was documented as
  turning transactions on and had silently stopped doing so. A Spark schema default is
  indistinguishable from an explicitly written value at transformer time, so the "set it unless the
  user did" transformer read the fork's `default: false` as the user's choice. Writes were
  non-atomic with nothing raising.
- **[ADR-23](ADR-23-merge-by-fast-forward-or-refuse.md)** — SQLite's file change counter was used
  as the fast-forward test because it is documented to move on every write transaction. In WAL
  mode it does not, so merge saw no divergence in a rewritten database and discarded the origin's
  writes.

## Still open

[ADR-20](ADR-20-choose-a-durability-level.md) is undecided and the risk is live, and
[ADR-22](ADR-22-where-the-tenancy-runtime-lives.md) has shipped Option B — AshCell names its own
binder and the suite is green — but not its seam: how much of the fork's tenancy engine AshCell sits
on top of is still open, and Option C rests on an assumption nobody has tested, that the fork's
manager can defer eviction to an external policy. Beyond it, and
not yet worth an ADR each: every deploy migrates every cell; reads are not fenced the way writes
are; background jobs have no request boundary to route at; thundering herd on node loss;
`ObjectStore.list/2` has no S3 pagination, so it breaks past 1000 snapshots; snapshot and restore
are non-atomic whole-file operations; `assert_bound!/0` cannot detect a tenant mismatch; and a
rewrite path that forgets `await_repo?: true` gets [ADR-21](ADR-21-close-does-not-await-the-connection.md)'s
bug back silently.
