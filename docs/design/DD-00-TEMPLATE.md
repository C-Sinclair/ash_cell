# DD-00 — Template

> Copy to `DD-NN-short-kebab-title.md` for a library feature, or to
> `demos/<name>/docs/design.md` for a demo, and delete this blockquote. Sections marked
> *(optional)* can be dropped when they genuinely do not apply — but drop them, do not leave
> them empty, and do not drop **Non-goals**, **Where it stops**, or **Measurements**, which are
> the three that keep a design doc honest.

**Status:** draft | building | built | abandoned
**Date:** YYYY-MM-DD
**Decisions:** the ADRs this rests on, as `ADR-NN` links into [`docs/decisions/`](../decisions) — real files only, a link checker runs here
**Lands in:** the modules, demo, or fork change this becomes

## What this is

Two or three sentences. What gets built, and the shape of the thing.

## What this proves

The claims this feature or demo is *for*. Each one should be checkable — if a claim cannot be
tied to a test, a measurement, or a thing a reader can run, it is a hope rather than a claim.
Write them as a list, most load-bearing first.

## Why it needs a cell

The specific reason this needs single-writer, physically-isolated storage rather than a table
with a `tenant_id` column. If the honest answer is "it does not, but it is a good demonstration
of something else", write that — a demo that overstates the primitive is worse than one that
admits what it is standing in for.

For a demo, also state **where the cell is cut** — per tenant, per record, per user, per
window, per repository — and why that cut and not another.

## Non-goals

What this deliberately does not do. This is the most re-read section of every design doc in this repo,
because it is what stops scope arriving by accident later.

## Threat model *(optional — required for anything touching keys, isolation, or untrusted input)*

A table of adversary → what they get → what stops them. Include the rows where the answer is
"nothing stops them", because those are the rows that matter.

## Data model

Resources, attributes, and which side of a boundary each lives on — global store vs cell, or
Tier 0 vs Tier 1. Name the attributes that had to be denormalised across a boundary and why,
since cross-data-layer relationships support `load` only.

## Trade-offs

The alternatives considered at the *product* level, with their costs. Where a choice was
genuinely architectural, it belongs in an ADR instead — link it rather than restating it. Where
a measurement decided it, give the number.

## Measurements this must produce

The numbers this work owes, named in advance, with the shape of the run (dataset size, warm or
cold, median of how many). Naming them up front is what stops a convenient subset being reported
later. Note which of these are *cliffs* rather than slopes — a cliff needs the parameter that
triggers it stated, not just the good number.

## Staging

The order of the work, with what each stage makes checkable. A stage that produces nothing
verifiable is a stage that cannot be reviewed.

## Where it stops

The honest boundary. What a reader might reasonably assume is handled here and is not. For a
demo, this section and its README must agree; when behaviour changes, both are part of the
change.

## Open risks

Known-unresolved problems, each with what it would take to close. Do not promote a risk to
"handled" here without evidence somewhere else in the repo.
