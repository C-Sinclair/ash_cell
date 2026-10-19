# DD-14 — Leadership from the bucket

**Status:** draft
**Date:** 2026-09-09
**Decisions:** [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md), [ADR-18](../decisions/ADR-18-tenant-in-job-args.md), [ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md)
**Lands in:** `AshCell.Peer` and `AshCell.Peer.Lease` (new), `AshCell.Peers.Oban` (new, in a separate repo — see Trade-offs)

## What this is

Leader election by conditional write against an object store, with no shared database and no
distributed Erlang. `AshCell.Peer` is a GenServer that holds a TTL lease on a key and answers
`leader?/1` and `get_leader/1`. `AshCell.Peers.Oban` wraps it in the `Oban.Peer` behaviour so
Oban's global plugins work on a fleet that has no Postgres.

The second half needs no election at all. A cell already has exactly one owner, chosen by
`AshCell.Lease`, so the node holding a cell is the leader for that cell's scheduled work.

## What this proves

- **An Oban fleet on SQLite can have cross-node leadership.** `Oban.Config` puts
  `{Oban.Peers.Isolated, []}` on `Oban.Engines.Lite`, and `Oban.Peers.Isolated` sets
  `leader?: true` unconditionally, so today every node believes it leads and `Cron` inserts on
  every node. `Oban.Peers.Global` needs distributed Erlang and `Oban.Peers.Database` needs the
  Postgres the deployment removed. The bucket is the one shared thing left.
- **Leadership is keyed, not per-instance.** `Oban.Peers.Database` holds one row per Oban
  instance name, so it answers one question. `AshCell.Peer` takes an arbitrary key, which is
  what a caller reaches for `pg_advisory_lock/1` to get.
- **A cell's owner is already its leader.** No second election, no second object, no second
  clock. This closes the routing half of "background jobs have no request boundary to route at":
  a node can ask whether it should run a tenant's scheduled work before it runs it.
- **Failover is bounded by the lease TTL and nothing else**, measured against a killed leader.
- **Election costs one GET plus one PUT per instance per interval**, so the request bill is a
  number stated in advance rather than discovered.

## Why it needs a cell

It does not. It needs the *bucket* and the conditional write, both of which AshCell already
depends on, and it works in a deployment with no cells at all. What makes it belong here is that
AshCell has already paid for the bucket, already wrote the conditional-write lease, and already
has the failure mode documented in [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md).

The per-cell half is different, and that half genuinely needs a cell: it is leadership derived
from single-writer ownership rather than from a separate election.

## Non-goals

- **Not a job queue.** No queues, no workers, no retries, no `Oban.Job`. This is the `Oban.Peer`
  behaviour and nothing on the job side.
- **Not consensus.** No quorum, no membership, no failure detector. Two nodes can both believe
  they lead across a long pause, exactly as they can with `Oban.Peers.Database`.
- **Not a fence.** `leader?/1` is advisory, for the same reason `AshCell.Lease` is advisory:
  correctness has to come from a conditional write on the work itself, not from the lease.
- **Not a replacement for `Oban.Peers.Database`.** A deployment with Postgres should keep it.
  A round trip to S3 is slower than a row upsert and buys nothing there.
- **No notifier.** Oban's Database peer broadcasts `%{"down" => name}` on clean shutdown so
  another node elects immediately. There is no equivalent here, so a clean handoff is fast only
  because the leaving leader deletes its lease object.

## Data model

One object per key, outside the `cells/` prefix:

```
peers/<encoded key>/leader.json   {"owner": "web.1", "expires_at": 1788965198667, "generation": 7}
peers/<encoded key>/generation    "7"
```

The key goes through `AshCell.CellKey.encode/1`, because an Oban instance name or a tenant id
becomes an object-store prefix and sanitising is not injective
([ADR-07](../decisions/ADR-07-opaque-cell-keys.md)).

The body is `AshCell.Lease`'s minus `txid`. A peer has no durability log, so `Lease.claim/4` is
the wrong function to call: it reads `AshCell.Replicator.latest_txid/2` and fails the claim when
the listing fails, which is right for a cell and pointless for a peer. The generation counter
stays, for the same reason it exists in `AshCell.Lease` — derived from the lease body it restarts
at 1 on every clean handoff, and a generation that repeats is not usable as a fence by anything
built on top of this later.

## Trade-offs

**Where the code lives.** Three options.

| Option | Cost |
|---|---|
| A module in `ash_cell` | Adds an optional Oban dependency to a library that has none, for a feature with no tenancy in it |
| A demo under `demos/` | Demos prove claims about cells; this claims something about buckets |
| A separate repo, `ash_cell_peers` | Two repos to release, and the bare lease has to be exported from `ash_cell` or duplicated |

The recommendation is the separate repo, with `AshCell.Peer` and `AshCell.Peer.Lease` living in
`ash_cell` (no Oban dependency, useful on its own) and only the `Oban.Peer` adapter living
outside. A two-node demo goes in the new repo, because what it proves is about nodes rather than
about a cell cut ([ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md)).

**Reusing `AshCell.Lease` versus a sibling.** Reuse means threading a "no txid" mode through
`claim/4`, `take/5` and `write/7`, which puts a branch in the middle of the code
[ADR-08](../decisions/ADR-08-fence-by-shared-txid.md) exists to protect. A sibling module means
the conditional-write claim is written twice. The sibling is the smaller risk, and the two can be
unified later once `AshCell.Peer.Lease` has its own tests.

**Election interval.** Oban uses 30 seconds, halved for the current leader (`leader_boost: 2` in
`Oban.Peers.Database`). Keeping those numbers keeps the failover behaviour comparable. At one GET
and one PUT per election, a node that is not leading makes 5 760 requests a day, and the leader
makes 11 520. Those are counts from the interval, not measurements.

## Measurements this must produce

- **Election round trip**, median and p99 of 100 elections, against MinIO on localhost and
  against real S3 in one region. Both numbers, because the localhost one will not predict the
  other.
- **Failover time** from `kill -9` on the leader to another node reporting `leader?/1 == true`,
  median of 20 runs, at `ttl_ms: 30_000` and at `ttl_ms: 5_000`.
- **Duplicate fires** over a 10-minute two-node run of a one-second cron, counted. The expected
  answer is zero, and a non-zero answer is the interesting result.
- **Request cost** per node per day at the default interval, as a count.
- **Clean-handoff time**, leader shutdown to successor election, which should be an election
  interval rather than a TTL. This is the number the missing notifier costs.

## Staging

1. `AshCell.Peer.Lease` — claim, renew, release, holder — plus tests against MinIO, including two
   racers where exactly one wins.
2. `AshCell.Peer` GenServer: election timer, jittered backoff, `terminate/2` releasing the lease.
   Checkable by `leader?/1` on two peers in one VM against one bucket.
3. `AshCell.Peers.Oban` in the new repo, with an Oban configured for `Oban.Engines.Lite` and a
   `Cron` plugin. Checkable by counting inserted jobs across two nodes.
4. Per-cell leadership: `AshCell.Peer.leads_cell?/1` answered from `AshCell.Manager.lease/1`,
   with no object-store call at all.

## Where it stops

- **It says who may run the work. It does not run it, and it does not route it.** A job that
  lands on the wrong node still lands on the wrong node; this only lets that node decline.
- **A partitioned leader keeps answering `true` until its lease expires.** That is the stale-read
  gap [ADR-14](../decisions/ADR-14-bounded-read-staleness.md) already names for cells: fencing
  ([ADR-08](../decisions/ADR-08-fence-by-shared-txid.md)) protects writes, not reads.
- **Per-cell leadership is not per-cell activation.** Knowing this node owns `"acme"` is not the
  same as having the cell open, and a cold cell answers `false` because nobody owns it.
- **The Oban adapter is checked against one pinned Oban version.** `Oban.Peer` is a documented
  behaviour with a stable three-callback contract, and that is the whole of the promise.

## Open risks

- **Clock skew across nodes widens the window where two peers both believe they lead.** Closing
  it needs the work itself to be conditional, which is a per-plugin question and not one this
  can answer. Naming the exposure is what is owed here.
- **`if_none_match` support is assumed of the store.** `AshCell.ObjectStore` already requires it,
  but a peer deployment might reach for a store the cell path never touched. Needs a startup
  check that fails loudly rather than an election that silently always wins.
- **The `Oban.Peers.Isolated` claim rests on reading `Oban.Config` and `Oban.Peers.Isolated` in
  one checkout.** Re-verify against the version the adapter pins before the README states it.
