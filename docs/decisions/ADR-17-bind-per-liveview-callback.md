# ADR-17 — Bind per LiveView callback, never at mount, and track holders explicitly

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-01](ADR-01-bind-tenants-per-process.md) · [ADR-02](ADR-02-bind-in-the-data-layer.md) · [ADR-09](ADR-09-snapshot-before-releasing-the-lease.md)

## The decision

`AshCell.LiveView` rebinds from the tenant id on every callback, never once at `mount`. Because
per-callback binding drops the quiescence bind count to zero between callbacks, register the
session's presence separately in `AshCell.Holders`, a duplicate-key Registry, so a drain cannot
evict a cell a live user is mid-session with.

## Context

A LiveView process outlives any single repo instance: eviction, restart or drain gives the cell a
new pid. Binding once at `mount` binds a pid, and [ADR-01](ADR-01-bind-tenants-per-process.md)
already established that a pid is the wrong tenant handle for exactly this reason — it is unstable
across the process's own lifetime, let alone the LiveView's.

## Options considered

### Option A — bind once at mount

What it buys: one bind call, simplest code. What it costs: the binding points at a repo instance
that can be replaced under the LiveView without it knowing, so a later callback runs against a
stale or nonexistent connection. Rejected for the same reason a pid handle was rejected in
[ADR-01](ADR-01-bind-tenants-per-process.md).

### Option B — rebind from the tenant id on every callback

What it buys: every callback re-resolves a current, correct binding regardless of what happened to
the cell between callbacks. What it costs: introduces a gap — between callbacks there is no
binding at all, so nothing marks the cell as in use. Chosen, but not sufficient on its own.

### Option C — a plain counter for quiescence tracking

What it buys: simple increment/decrement bookkeeping. What it costs: a leaked increment (a
callback that binds but whose matching release never runs, e.g. a crash) permanently blocks
draining, because nothing ever brings the counter back to zero. Rejected.

### Option D — `AshCell.Holders`, a duplicate-key Registry

What it buys: self-cleaning holder tracking — a monitor removes the entry when the LiveView process
dies (e.g. a closed tab), so a leaked holder is not possible by construction. What it costs: a
Registry lookup and monitor per session rather than an integer. Chosen.

## Decision and why

The sequence that forced this: binding at mount is wrong because the LiveView outlives the pid it
would bind. Fixing that with per-callback rebinding is correct but creates a second problem —
between callbacks, the bind count is zero, so a drain could see no bound work and evict a cell a
user is still actively viewing. The fix for that second problem cannot be a counter, because a
counter can leak upward without a way back down, and a leaked holder would then permanently block
draining. `AshCell.Holders` avoids that by tracking presence via process monitors instead of manual
increment/decrement: the registration disappears exactly when the process that made it dies, with
no separate release call that can be skipped.

Reconnects are routed to the lease holder via `AshCell.Plug.OwnerRouting`, so a reconnecting client
reaches the node that actually owns the cell rather than binding somewhere new.

Since resources with `AshCell.Resource` no longer need a caller to bind at all
([ADR-02](ADR-02-bind-in-the-data-layer.md)), `bind_held/1` remains for LiveViews but only for its
holder registration; its binding half is now redundant.

## Consequences

- **What it rules out.** Binding once per LiveView lifecycle. Any future LiveView helper must
  rebind per callback, not cache a connection across callbacks.
- **What it makes worse.** Every callback pays a rebind, rather than amortising one bind across the
  LiveView's life.
- **What stays open.** Whether `bind_held/1`'s redundant binding half should be removed now that
  `AshCell.Resource` binds independently.
- **What now depends on it.** `AshCell.Plug.OwnerRouting`'s reconnect routing assumes holders are
  tracked in `AshCell.Holders`; the drain path in
  [ADR-09](ADR-09-snapshot-before-releasing-the-lease.md) assumes quiescence tracking reflects real
  holders, not a leakable counter.

## Evidence

- Commit `cc8b248`.

## Notes

None beyond the above.
