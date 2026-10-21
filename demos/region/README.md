# Region

A project tracker where each organisation names the region its data is stored in, and a project can name a stricter region than its organisation. Each region is its own object-store bucket. One node serves every region. The design is in [docs/design.md](docs/design.md), and the library decision it rests on is [ADR-30](../../docs/decisions/ADR-30-route-the-store-by-cell-key.md).

## What it proves

- A cell's snapshots, `lease`, and `generation` object land in the bucket its cell key names and in no other. `test/region_test.exs` ships an organisation's cell and a project's own cell, then reads both buckets for each key.
- `Region.Scope` is the only code that builds a cell key. Its `Ash.Scope.ToOpts.get_tenant/1` returns `"<home_region>:<org_id>"`, or `"<region>:<org_id>:<project_id>"` for a project whose region differs from its organisation's. Callers pass `scope:` and never `tenant:`.
- `Region.Stores.store_for/1` chooses the bucket from the key's region prefix alone, so the region cannot change between two statements of one action.
- A project whose region is outside its organisation's `allowed_regions` is refused by the `Region.Work.RegionAllowed` validation. The test asserts that neither bucket holds an object for the organisation and that no cell file was created.
- A key naming a region the fleet has no bucket for fails instead of falling back to a default bucket.

## Where it stops

- This is storage residency, not data residency. The node holding the plaintext can be anywhere, and in this demo it is one machine.
- Two MinIO buckets on a laptop are one physical location. The demo proves the routing and not the geography.
- [ADR-16](../../docs/decisions/ADR-16-isolation-is-blast-radius.md) applies. Separate buckets reduce blast radius and support a sales position. They are not by themselves compliance with GDPR or any other regime.
- Logs, telemetry, and the global `Region.Accounts.Org` table are not region-routed. The `Org` row names the region and lives in one global SQLite file.
- Changing an organisation's region is not supported. The old cell stays where it was.
- A wrong tenant value is a silent misplacement. `Region.Scope` and its test guard it. The library checks that a key names a known region, not that it names the right one.
- Fencing per region is argued in the design, not tested here. The bucket audit script and the bind-cost measurement named in the design are not built yet.

## Running it

The suite needs MinIO with both buckets, and `exqlite` built against SQLCipher.

```bash
../../scripts/minio.sh                      # creates ashcell-test and ashcell-test-eu
source .envrc
mix deps.get && mix deps.compile && mix deps.compile exqlite --force
mix test
```

`config/config.exs` maps `"us"` to `ashcell-test` and `"eu"` to `ashcell-test-eu`.
