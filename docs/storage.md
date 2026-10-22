# How a cell stores data

A cell is one SQLite file on one node, owned by one process. Its data reaches durable storage in two steps: a commit is fsynced to the node's disk, and later the whole file is shipped to an object store. Each step covers a different failure, and this page says which.

## The two steps

1. **Commit to the node's disk.** A write commits to the cell's SQLite file in WAL mode. Cells run `synchronous: :full`, so the WAL is fsynced before `COMMIT` returns and before the caller is acknowledged. See [ADR-20](https://github.com/C-Sinclair/ash_cell/blob/main/docs/decisions/ADR-20-choose-a-durability-level.md).
2. **Ship to the object store.** `AshCell.Replicator` checkpoints the WAL into the file and uploads the whole file as a snapshot. This happens after the acknowledgement, never before it. A cell is shipped:
   - on a schedule set by `AshCell.SnapshotPolicy`;
   - when the node drains, before it releases the cell's lease ([ADR-09](https://github.com/C-Sinclair/ash_cell/blob/main/docs/decisions/ADR-09-snapshot-before-releasing-the-lease.md));
   - when a branch is merged.

A node that claims a cell restores its newest snapshot with `AshCell.claim/2`, unless it already holds the lease and has the file on disk.

## What each failure loses

| Failure | Lost |
|---|---|
| Process crash, or the BEAM restarts | nothing |
| Power cut or kernel crash, and the same disk comes back | nothing |
| The node or its disk is gone, and the cell is restored from the object store | every write since the last snapshot shipped |

The first two rows hold because of `synchronous: :full`. Under exqlite's default, `:normal`, the second row lost every acknowledged commit in a replayed power cut, while `:full` lost none. `scripts/power_loss/run.sh` and the `durability` CI job check this on every push.

The third row is the recovery point, and `synchronous` does not change it. Shrinking it to zero means acknowledging a commit only once it is in the object store. That is Path B in [the spec](spec.md), and it is deliberately not built.

## When a cell ships

`AshCell.SnapshotPolicy` checks each cell every `interval_ms`, with jitter so a fleet does not ship at once. A cell ships when either holds:

| Option | Default | Ships when |
|---|---|---|
| `wal_bytes` | 4 MiB | the WAL has grown past this |
| `max_age_ms` | 60 seconds | anything is unshipped and the last shipment is this old |
| `interval_ms` | 5 seconds | how often a cell asks, not how often it ships |

A cell with an empty WAL never ships, so a dormant cell costs nothing. With the defaults, the recovery point for a cell with steady writes is up to 60 seconds. Set the policy on the fleet:

```elixir
{AshCell, store: store, snapshot: [wal_bytes: 1_000_000, max_age_ms: 30_000]}
```

`snapshot: false` ships only on drain. A fleet with no `store:` never ships.

## Choosing a durability level

`AshCell.Repo` sets `synchronous: :full` unless the repo already chose a level. Set one in the repo's config to apply it to every cell:

```elixir
config :my_app, MyApp.CellRepo, synchronous: :normal
```

Or set it per cell in `init/2`, which sees the cell key:

```elixir
def init(context, config) do
  config =
    if String.starts_with?(config[:tenant], "cache:"),
      do: Keyword.put(config, :synchronous, :normal),
      else: config

  super(context, config)
end
```

Lowering it is a trade you make for a cell whose contents can be rebuilt. These are the costs measured with `scripts/synchronous_probe.exs` on a GitHub Actions Linux runner, median of 5 runs:

| Rows per transaction | `:normal` | `:full` |
|---|---|---|
| 1 | 49 µs, about 20,000 commits/s | 271 µs, about 3,700 commits/s |
| 100 | 186 µs | 404 µs, about 248,000 rows/s |

The fsync is paid per commit, not per row, so batching writes into one transaction recovers most of the cost. The runner's disk is not your production disk. Run the probe on the disk you deploy to.

## Where snapshots live

Snapshots, the lease, and the generation counter for a cell sit under one prefix, `cells/<encoded cell key>/`. The cell key is escaped by `AshCell.CellKey.encode/1`, so two keys never share a prefix.

- **Snapshots** are keyed by transaction id and written with a conditional PUT. A node that has lost the cell without noticing tries to write a txid its successor already wrote, and fails before it acknowledges anything. That is the fence, and it is why snapshots are keyed by txid and not by lease generation ([ADR-08](https://github.com/C-Sinclair/ash_cell/blob/main/docs/decisions/ADR-08-fence-by-shared-txid.md)).
- **The lease** says which node owns the cell. It makes the fleet efficient, not correct. Two nodes that both believe they hold it are stopped by the conditional snapshot write.
- **The store itself** can be one bucket, or one per cell. A module implementing `AshCell.ObjectStore.Router` picks a store from the cell key, which is how `demos/region` keeps each region's cells in its own bucket ([ADR-30](https://github.com/C-Sinclair/ash_cell/blob/main/docs/decisions/ADR-30-route-the-store-by-cell-key.md)).

## Where it stops

- **Reads are not fenced.** A node that has lost a cell can serve stale reads from it until it notices.
- **Snapshots are whole files.** Shipping costs grow with the database's size, not with how much changed. Page-level replication is not built.
- **The cost of `:full` on a production disk is unmeasured,** and so is the cost of many cells committing at once on one disk.
- **Encryption at rest is per cell, and the node holds the key.** A snapshot is as encrypted as the file it copies.
