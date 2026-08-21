---
name: Feature request
about: Suggest something AshCell should do
labels: enhancement
---

## The problem

<!-- What are you trying to do, and what makes it hard today? Describe the
     situation rather than the solution — the constraints here are unusual
     enough that the obvious fix is often the wrong one. -->

## What you'd like

## What you've tried

<!-- Including workarounds. A workaround that nearly works is useful signal. -->

## Does it cross a cell boundary?

<!-- A cell is one file with one writer. Transactions, joins, and aggregates
     cannot span two cells — separate connections, and WAL loses cross-database
     atomicity even with ATTACH. If the request needs one of those across cells,
     say so: the answer is likely a different cell cut rather than a feature. -->
