# Region — design

**Status:** building
**Date:** 2026-10-21
**Decisions:** [ADR-07](../../../docs/decisions/ADR-07-opaque-cell-keys.md), [ADR-08](../../../docs/decisions/ADR-08-fence-by-shared-txid.md), [ADR-16](../../../docs/decisions/ADR-16-isolation-is-blast-radius.md), [ADR-19](../../../docs/decisions/ADR-19-the-cell-cut-is-a-choice.md), [ADR-23](../../../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md), [ADR-30](../../../docs/decisions/ADR-30-route-the-store-by-cell-key.md)
**Lands in:** a per-cell store option on `AshCell.Supervisor` and `AshCell.Manager`, and a new demo at `demos/region/`

## What this is

A project tracker where each organisation names the region its data is stored in, and a project can name a stricter region than its organisation. Each region is its own object-store bucket. A cell's snapshots, lease, and generation object are written only to the bucket of the region its cell key names. One node serves every region.

## What this proves

1. A cell's durable state lands in one region's bucket and no other. The test lists every bucket after a run and asserts each cell's prefix appears in exactly the bucket its key names: snapshots, `lease`, and `generation`.
2. The region is fixed by the cell key, so it cannot change between two statements of one action. `AshCell.CellKey.resolve/1` produces `"<region>:<org>"` or `"<region>:<org>:<project>"`, and the store is chosen from that key alone.
3. A project whose region disagrees with its organisation's allowed regions is refused at creation, before any cell exists. Nothing is written to either bucket.
4. An unknown region fails the bind. A key naming `"ap"` on a fleet configured for `"eu"` and `"us"` raises instead of falling back to a default bucket.
5. Fencing still holds per region. The `test/fencing_test.exs` displaced-writer case passes against a region bucket, because the txid namespace ([ADR-08](../../../docs/decisions/ADR-08-fence-by-shared-txid.md)) lives in the same bucket as the snapshots it fences.

## Why it needs a cell

A row-per-tenant database puts every organisation in one storage system, so residency is a property of the whole database or of a partition scheme the database owns. A cell is a file with its own snapshot prefix, so residency becomes a choice made per file: which bucket that prefix lives in.

The cell is cut **per organisation** by default, with a project able to take its own cell when it names a stricter region. That is two cuts in one fleet, which [ADR-19](../../../docs/decisions/ADR-19-the-cell-cut-is-a-choice.md) allows because the key is opaque. The finer cut exists only because a project's region can differ from its organisation's. Without that, per organisation is enough.

## Non-goals

- Compute residency. One node serves every region, so EU plaintext passes through whatever machine runs the demo. Node placement is spec stage 3.
- Moving a cell between regions. A move is a snapshot copy plus a lease handoff, and the old region's history has to be deleted or kept on purpose. Out of scope.
- Region-local encryption keys. Every cell uses the fleet's key scheme unchanged.
- Cross-region branching. `AshCell.fork/2` copies a snapshot within one store. A branch whose source and target regions differ is refused, not copied.
- Choosing a region from a record at query time. The resolver sees the tenant and not the query ([ADR-07](../../../docs/decisions/ADR-07-opaque-cell-keys.md)), so the application puts the region in the tenant value.
- A compliance claim. See where it stops.

## Threat model

| Adversary | What they get | What stops them |
|---|---|---|
| A bug that binds an EU organisation with a US-prefixed tenant | Writes to the US bucket | Nothing in the library. `Region.Scope.get_tenant/1` is the only constructor, and a test asserts it. |
| A request naming a region the fleet does not know | — | The store lookup raises at bind. |
| A project created with a region outside its organisation's allowed list | — | The `create` action's validation, before a cell is opened. |
| An operator with credentials for every bucket | Everything | Nothing. Per-region credentials would narrow this and are not in scope. |
| The node itself | Plaintext of every region | Nothing. This is the compute-residency non-goal. |

## Data model

Global store (its own repo, per [ADR-06](../../../docs/decisions/ADR-06-own-repo-for-shared-tables.md)):

- `Org`: `name`, `home_region`, `allowed_regions`.

`Region.Scope` holds the actor, the `Org`, and optionally a project. It implements `Ash.Scope.ToOpts`, and its `get_tenant/1` is the only code that builds a cell key: `"<region>:<org_id>"`, or `"<region>:<org_id>:<project_id>"` for a project with its own region. Callers pass `scope:` and never `tenant:`.

Cell, keyed `"<region>:<org_id>"` or `"<region>:<org_id>:<project_id>"`:

- `Project`: `name`, `region`. `region` is denormalised from the global side so a cell can be read without the global store.
- `Task`: `title`, `status`, belongs to a project.

The global `Org` row is the source of the region. A cell never decides its own region.

## Library change

Every store call in `AshCell.Replicator`, `AshCell.Lease`, and `AshCell.Branch` already takes the store as an argument. What is fleet-wide is where it comes from: `AshCell.Manager` holds one `store` and passes it to every `AshCell.Cell` it starts.

The change lets the supervisor's `store:` option be a single `%AshCell.ObjectStore{}` (unchanged) or a module implementing `c:store_for/1`, which maps a cell key to a store or raises. `AshCell.Manager.store/1` takes a cell key. The four call sites are `AshCell.Manager` starting a cell, `AshCell.Drain.run/1` (which drains per cell, so it looks up per cell), `AshCell.Plug.OwnerRouting`, and `require_store!/0` in `AshCell`. Branching checks that source and target resolve to the same store.

`store_for/1` takes the cell key and not the tenant or the scope. A scope exists only while an Ash action is called. `AshCell.Manager` starting a cell, `AshCell.Drain.run/1` walking resident cells, and a periodic snapshot all pick a store with no scope and no tenant in hand. They have only the cell key. The scope decides what the key is, and `store_for/1` routes the key. [ADR-30](../../../docs/decisions/ADR-30-route-the-store-by-cell-key.md) records the decision.

## Trade-offs

- **Region in the key, or a region column the router reads.** A column means opening the cell to learn where its cell lives. The key carries it with no lookup, at the cost that changing region changes the key.
- **One bucket per region, or one bucket with a region prefix.** A prefix proves nothing about residency, because the bucket has one location. Separate buckets are what a real deployment would configure. Locally they are two MinIO buckets, which stands in for two locations and does not demonstrate one.
- **Refuse a mismatched project, or silently move it to the organisation's region.** Refusal. A silent move is the residency failure this demo exists to rule out.

## Measurements this must produce

- Bucket audit after the end-to-end run: for each region bucket, the list of cell prefixes, and the count of prefixes in the wrong bucket. The required number is 0.
- Bind cost of the router. The median of 1,000 warm binds with a static store, compared with the median through `store_for/1`. This must be measured, not assumed small.
- `mix test` for the library passing with `store:` still a single struct, so the existing demos are unaffected.

## Staging

1. Done: `store_for/1` in the library, with a test that two cells with two region prefixes write to two buckets. Existing suite unchanged.
2. Done: branch refusal across stores, with a test.
3. Done: the demo app: `Org`, `Project`, `Task`, the resolver, the creation validation.
4. The bucket audit script and the README, including where it stops.

## Where it stops

- This is storage residency, not data residency. The node holding the plaintext can be anywhere, and on this demo it is one machine.
- Two MinIO buckets on a laptop are one physical location. The demo proves the routing and not the geography.
- [ADR-16](../../../docs/decisions/ADR-16-isolation-is-blast-radius.md) applies: separate buckets reduce blast radius and support a sales position. They are not by themselves compliance with GDPR or any other regime.
- Logs, telemetry, and the global `Org` table are not region-routed. The `Org` row names the region and lives in one global store.
- Changing an organisation's region is not supported. The old cell stays where it was.

## Open risks

- A wrong tenant value is a silent misplacement. The demo guards it with `Region.Scope.get_tenant/1` and a test, and the library cannot check it. Closing it would need the resolver to verify the key against a source of truth, which is a lookup per bind.
- `AshCell.Plug.OwnerRouting` reads the store before a cell is bound. It needs the cell key at that point, which may not be resolvable from every request. Find out in stage 1.
