# Console — one cell per tenant

A Phoenix LiveView console over a fictional multi-clinic healthcare SaaS. Each clinic is one
encrypted SQLite file owned by one process at a time; a global Postgres holds the clinic
registry. Six panels, each one making a single claim you can check without trusting the
application.

This is the demo the numbers in the [workspace README](../../../README.md) come from.

## What it proves

| Claim | Panel | How it is shown, not asserted |
|---|---|---|
| Isolation is **physical**, not a `WHERE tenant_id = ?` | 1 · Isolation | Each clinic's file is read straight off disk, bypassing Ash entirely. A patient typed into clinic A appears in A's bytes and in no other file. |
| Cells are **encrypted at rest** | 1 · Isolation | Live hexdump of a cell beside an unencrypted control. The `sqlite3` CLI reports "file is not a database" for the cell; the control opens fine and its patient names are legible in the dump. Zero plaintext markers found in the encrypted file. |
| **Key revocation shreds one tenant** | 1 · Isolation | Revoke a clinic's key: the file is still on disk, byte-for-byte, and zero rows are readable. Every other clinic keeps serving. |
| **Deletion removes the bytes** | 1 · Isolation | Deleting a clinic is `rm`. No vacuum, no tombstones, no dead tuples still holding the data — contrast with what Postgres does on `DELETE FROM patients`. |
| Ash routes transparently to the right cell | 2 · The fleet | The same resource, the same action, a different tenant. Resident cells are listed with their pids; the registry rows come from Postgres, the clinical rows from the cell. |
| **N+1 immunity**, and it is not a cache trick | 3 · Speed | A deep three-level `load` (clinic → patients → encounters → observations) with the generated SQL shown. |
| The comparison is **fair** | 3 · Speed | The identical dataset is seeded into Postgres too, with proper indexes, a warm pool, and the query a competent engineer would write — plus a raw-SQL, no-framework third row. If AshCell only wins against a handicapped Postgres, that is a finding, not a demo. |
| Data really is **in the object store** | 4 · Object store | Snapshot a cell, then fetch the object back and open it. Destroy the local file and watch the cell restore from the bucket. |
| Exactly one writer wins a contested cell | 4 · Object store | The lease and generation keys are shown as they change hands. (The 12-claimant race lives in `ash_cell/test/object_store_test.exs`; the panel shows the mechanism, the test proves the exclusion.) |
| Ordinary CRUD is ordinary | 6 · Records | Create, edit, delete patients in a clinic. Cross-clinic search is an explicit fan-out over cells, because there is no implicit merge — that is the cost side of the ledger, shown rather than hidden. |
| **A deploy drains cleanly** | 5 · The deploy | Simulated deploy: seal, quiesce, checkpoint, snapshot, *release lease*, close. The release is the win — without it a successor waits out the full lease TTL for every tenant, every deploy. |

### Measured numbers

60 patients / 180 encounters / 720 observations per clinic, median of five, both sides warmed:

| | Deep three-level load |
|---|---|
| AshCell (Ash + SQLite) | **~3.0 ms** |
| Postgres (Ash + Postgres) | ~9.1 ms |
| Postgres (raw SQL, no framework) | ~2.8 ms |

The third row is the interesting one. AshCell going through the whole framework lands level
with hand-written SQL, because the framework's per-query cost stops being hidden behind a
network hop. Re-run these yourself from panel 3 — the console reports what it measured on
your machine, not these numbers.

## What it does *not* prove

Stated here so the panels do not have to over-claim:

- **HIPAA does not require physical isolation.** The isolation panel is a blast-radius and
  enterprise-sales argument, not a regulatory one.
- **BYOK here is not confidential computing.** The node holds the plaintext key in order to
  serve the cell.
- **RPO is ~1s, not 0.** The object-store panel shows Path A: local fsync plus async
  shipping. Path B (gating acks on the segment PUT) is deliberately deferred.
- **Reads are bounded, not fenced.** A partitioned node refuses to serve past the lease TTL,
  which is the one place clock skew matters.
- **Every deploy migrates every cell**, and `fly-replay` does nothing for an open LiveView
  websocket. The deploy panel shows the drain, not a solution to that.

## Running it

Needs Postgres, MinIO, and an `exqlite` built against SQLCipher.

```bash
minio server /tmp/ashcell-minio --address :9010   # MINIO_ROOT_USER=ashcell MINIO_ROOT_PASSWORD=ashcellsecret
mc alias set ashcell http://127.0.0.1:9010 ashcell ashcellsecret
mc mb ashcell/ashcell-demo
```

```bash
source .envrc                       # EXQLITE_USE_SYSTEM and the SQLCipher paths
mix deps.compile exqlite --force    # a missing env var here fails *silently*
mix ecto.setup
mix run -e 'Demo.Seed.run(patients: 60)'
mix phx.server
```

Then open http://localhost:4000. Panel order is deliberate: the compliance evidence comes
first, because it is the part that does not require trusting the application.

## Layout

| Path | Role |
|---|---|
| `lib/demo/cells/schema.ex` | Versioned cell schema, applied on activation before the cell serves. Migration is a *fleet* operation — there is no moment when every clinic is on the same version; the mitigation is that a failure takes down one clinic, not all of them. |
| `lib/demo/cells/vault.ex` | Per-tenant keys. One key per cell, so revocation is per tenant. |
| `lib/demo/clinical/resources.ex` | The tenanted resources (patient, encounter, observation) on `AshCell.Resource`. |
| `lib/demo/global/clinic.ex` | The one non-tenanted resource, on its *own* repo module — a shared table sharing the cells' repo module would silently inherit tenant bindings and write rows into whichever cell happened to be bound. |
| `lib/demo/comparison/resources.ex` | The same resources against Postgres, for panel 3. |
| `lib/demo/evidence.ex` | The proofs: hexdumps, encryption reports, object listings, destroy-and-restore, export, delete. |
| `lib/demo/benchmark.ex` | The timed workload, both data layers. |
| `lib/demo/seed.ex` | Builds the fleet, and the identically-shaped Postgres dataset. |
| `lib/demo_web/live/console_live.ex` | All six panels. |
