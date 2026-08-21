# ADR-16 — Claim physical isolation as blast-radius reduction, not as compliance

**Status:** corrects an earlier belief
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · [ADR-15](ADR-15-sqlcipher-from-the-system-build.md) · [ADR-04](ADR-04-transactions-behind-an-opt-in-flag.md)

## The decision

Pitch physical isolation as a blast-radius reduction against app-level authorization bugs, and as
an enterprise sales position. Do not pitch it as a regulatory requirement, as confidential
computing, or as a basis for cross-tenant analytics. These are separate, and an earlier draft of
the pitch conflated them.

## Context

An earlier pitch overstated what database-per-tenant buys, on several fronts at once. Each claim
was checked against source or against the demo it was made about, and each did not hold.

## Options considered

### Option A — keep the compliance framing

Sells harder to an audience that hears "HIPAA" and stops evaluating. Costs credibility with anyone
who checks: the HIPAA Security Rule requires access controls, audit and encryption; auditors
accept row-level tenancy routinely. A claim an auditor can falsify in one sentence is worse than no
claim.

### Option B — keep the "zero trust" framing for BYOK

Sells well against a threat model of "we don't want the vendor to see the data." Costs accuracy:
the node holds the plaintext key to serve, so a server shipping the JS that touches the master key
is not zero-trust. A compromised *active* server can exfiltrate keys at next login. Revoking a key
stops future hydrations; it does not eject a resident cell.

### Option C — correct the pitch to blast-radius reduction

Buys an honest, still-useful claim: protection against a stolen disk, a leaked backup, a rogue DBA,
or a subpoena on the host. Costs the sales punch of "compliant" and "zero trust." Chosen.

## Decision and why

Each dropped claim was checked and failed:

- **HIPAA does not require physical isolation.** The Security Rule's bar is access controls, audit
  and encryption, and auditors accept row-level tenancy routinely. Physical isolation is not a
  regulatory advantage.
- **BYOK here is not confidential computing.** The node holds the plaintext key to serve. Revoking
  a key stops future hydrations; it does not eject a resident cell already running with it.
- **Cross-tenant analytics over S3 snapshots re-comingles the data the isolation pitch disclaims.**
  A DuckDB-over-snapshots analytics plane rebuilds the co-mingled PHI store the isolation pitch
  says does not exist — exactly what an auditor would look at.
- **"Zero changes" moving AshSqlite resources to AshCell was false.** `can?/2` declares false for
  aggregates, lateral joins, distinct and locks, so every `aggregates do ... end` block breaks.
  (Transactions were later restored; see [ADR-04](ADR-04-transactions-behind-an-opt-in-flag.md).)
  Demo panels had to be redesigned around expression calculations, which are supported including
  sort, instead of aggregate-backed sorts.
- **A server that ships the JS touching the master key is not zero-trust.** The shroud demo's design doc
  carries an explicit threat-model table including the row "compromised server, active → Tier 1
  broken."

What survives after dropping these: physical isolation is a genuine blast-radius reduction against
app-level authorization bugs — a bug that leaks one tenant's rows cannot reach another tenant's
file — and it is an effective enterprise sales position on its own terms, without dressing it as a
regulatory or cryptographic guarantee.

The honest performance pitch changed with it, from point-read microseconds to N+1 immunity. The
measured result, on 60 patients / 180 encounters / 720 observations per clinic, median of five runs,
both sides warmed, deep three-level load:

| | AshCell | Ash + Postgres | raw SQL on Postgres |
|---|---|---|---|
| median | ~3.0 ms | ~9.1 ms | ~2.8 ms |

The third row is the point: raw SQL is close to AshCell and far from Ash + Postgres, so the
framework cost stops being hidden behind a network hop. That is a defensible performance claim
where "point-read microseconds" was not.

## Consequences

- **What it rules out.** Pitching AshCell as a HIPAA control, as confidential computing, or as a
  platform for cross-tenant analytics over snapshots.
- **What it makes worse.** The sales story is narrower and requires more explanation than
  "compliant" or "zero trust" would have.
- **What stays open.** Whether the blast-radius argument alone carries the enterprise pitch without
  the compliance framing behind it.
- **What now depends on it.** The shroud demo's threat-model table; the demos' aggregate-free query
  patterns using expression calculations; any future pitch material for this project.

## Evidence

- Benchmark: 60 patients / 180 encounters / 720 observations per clinic, median of five runs, both
  sides warmed, deep three-level load. AshCell ~3.0 ms; Ash + Postgres ~9.1 ms; raw SQL on Postgres
  ~2.8 ms.
- `can?/2` false for aggregates, lateral joins, distinct and locks — falsifies the "zero changes"
  claim.
- shroud design-doc threat-model table, row "compromised server, active → Tier 1 broken."

## Notes

This ADR corrects an earlier draft of the pitch rather than introducing a new decision — the
underlying architecture (one encrypted SQLite file per tenant, BYOK) is unchanged. What changed is
what is claimed about it.
