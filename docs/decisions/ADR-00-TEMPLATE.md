# ADR-00 — Template

> Copy this file to `ADR-NN-short-kebab-title.md`, take the next free `NN`, and delete this
> blockquote. Keep the section order: an ADR is read by skimming headings, so a reordered one
> is harder to use even if the content is identical.
>
> **Edit ADRs in place.** When a decision changes, correct the file so it states what is true
> now — do not open a new ADR to supersede it, and do not leave a reader to work out which of
> two files is current. Git carries the history: `git log -p` on the file, or a SHA in the
> **Notes** section, is how you point at what it used to say. Set **Status** to `reversed` if
> the decision went the other way, note the change on the **Last changed** line, and rewrite
> the body rather than appending a correction to the bottom.

**Status:** proposed | accepted | reversed | corrects an earlier belief
**Last changed:** YYYY-MM-DD — what changed, if this is not the original version
**Date:** YYYY-MM-DD
**Deciders:** who settled it
**Relates to:** the design doc under `../design/`, [`docs/spec.md`](../spec.md), and the demo or
module this lands in. Link real files only — a link checker runs over this directory, so write
placeholders in backticks rather than as markdown links.

## The decision

One paragraph, in the imperative, stating what we do. A reader who stops here should be able to
act correctly. Put the *what* here and the *why* below — do not make them read the whole file to
find out what was decided.

## Context

What forced the choice. A question we could not answer, a constraint found in someone else's
source, a measurement that came back wrong, a claim that turned out false. Name the thing that
made a decision necessary — an ADR with no forcing function is a preference, not a decision.

## Options considered

Every option that was genuinely on the table, including the one we took. An option listed
without its cost is an option that was never really considered.

### Option A — name it

What it buys. What it costs. Why it lost (or won).

### Option B — name it

Same. Include options that were *tried and abandoned*; those are the most valuable rows, because
the next person will otherwise try them again.

## Decision and why

The reasoning that actually settled it — not a summary of the options, but the argument that
picked one. If a measurement decided it, the number goes here. If the deciding factor was taste
or sequencing rather than evidence, say so plainly; a decision made on judgement is fine, a
decision that *pretends* to evidence it does not have is not.

## Consequences

What this costs us, stated as flatly as what it buys.

- **What it rules out.** Things that are now hard or impossible. Be specific.
- **What it makes worse.** Every real decision makes something worse.
- **What stays open.** Questions this does not answer. Do not let an ADR imply closure it
  did not achieve.
- **What now depends on it.** Code, docs, or demos that would break if this were revisited.

## Evidence

Where the claims above can be checked. Verbatim, so a reader can go and look:

- test files and the specific test name
- measurements, with the number, the shape of the run, and what was warmed
- source locations that constrain us, as `path:line`, plus the version they were read at
- what was *not* verified, and what it would take to verify it

"Measure before claiming" applies to ADRs more than anywhere else, because an ADR is what
somebody trusts instead of re-deriving. If an option's cost is estimated rather than measured,
label it estimated.

## Notes

Anything that does not fit above: prior art, what a future revisit would need to look at, links
out to the transcript or issue where the argument happened.
