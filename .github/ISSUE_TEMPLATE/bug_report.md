---
name: Bug report
about: Report something that isn't working
labels: bug
---

## Description

<!-- What went wrong? -->

## Reproduction

<!-- The smallest resource and call that triggers it. -->

```elixir
```

## Expected behavior

## Actual behavior

<!-- Include error messages and stack traces. -->

## Environment

- `ash_cell` version or commit:
- `ash_sqlite` fork commit:
- `ash` version:
- Elixir / OTP version:
- Operating system:

## Configuration

<!-- Delete what doesn't apply. These change which code paths run, so they are
     usually the first question anyway. -->

- Encryption (`:key_for` set)? yes / no
- If yes, does `mix cipher.check` pass?
- Object store (`:store` set)? yes / no — which implementation (S3, MinIO, R2, ...)?
- Custom `AshCell.CellKey` resolver? yes / no — what is the cut?
- Single node or multiple?
