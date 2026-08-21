<!-- If this PR fixes an issue, add: Fixes #123 -->

## What

<!-- A short description of what changed. -->

## Why

<!-- Why is this change needed? Link to an issue or motivate inline. -->

## Notes for reviewers

<!-- Anything non-obvious: tricky decisions, follow-ups, what to look at first. -->

## Checklist

- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors` and `mix test` pass locally, against a running MinIO
- [ ] Any new claim about behaviour is backed by a test against a real file or a real store, not a mock
- [ ] Any performance number comes from a run, not an estimate
- [ ] Public API changes are reflected in `usage-rules.md` and the README
- [ ] A demo whose behaviour changed has its README updated
- [ ] `CHANGELOG.md` has an entry under `## [Unreleased]`
