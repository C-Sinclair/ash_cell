# Stage 0 probes

Run before any app code, because each one could invalidate part of `prd.md`. Numbers are
from a run on this machine (M-series, macOS 24.6, SQLCipher 4.x, PostgreSQL 17.10,
Elixir 1.19.1/OTP 28), not estimates.

## 1. Is a passkey's PRF output usable as a key? — needs a human

`probes/prf/index.html`. Not automatable: it needs a real authenticator and a real user
gesture. Serve it and click through:

```
cd probes/prf && python3 -m http.server 8111   # then open localhost:8111
```

WebAuthn needs a secure context, so `file://` will not do; `localhost` counts as secure.

The probe answers the only question that matters, which is **not** "do passkeys work"
but "is the PRF output *deterministic*". It registers a credential with `extensions:
{prf: {}}`, asserts twice with a fixed salt, and compares. It then does the real thing
end to end — HKDF-SHA256 to a KEK, AES-GCM wrap and unwrap of a 32-byte master key — so
a pass means the Stage 3 key path works on that platform, not merely that an extension
was acknowledged.

**Status: unrun.** Needs one pass per target platform. Record results here as a table
(browser, authenticator, `prf.enabled`, deterministic, round-trip) — if the common case
fails, the recovery passphrase is promoted from fallback to primary and Stage 3 changes
shape.

## 2. Is a SQLCipher cell's WAL actually ciphertext? — yes

`probes/ciphertext/probe.sh`. Stands in for the Litestream probe, which cannot run here
(litestream is not installed). Litestream replicates WAL frames verbatim, so "are the S3
segments opaque?" reduces to "are the WAL frames opaque?", and that is answerable now.

The care needed is in the procedure rather than the assertion. SQLite checkpoints and
deletes the WAL on clean close, so a probe that opens, writes and exits finds no WAL and
reports a pass it never earned — the first version of this probe did exactly that. The
writer is therefore held open on a FIFO while the files are inspected, which is also the
realistic case: a WAL only exists on disk for Litestream to ship while a connection is
live or after a node died.

```
main file (encrypted, held open):  no plaintext, 4096 bytes
WAL      (encrypted, held open):   no plaintext, 12392 bytes
control  (unencrypted, same procedure): leaks the canary in its WAL, as required
header:  8d27da07c11071f1 — not "SQLite format 3"
```

The control matters as much as the result: without a negative case leaking under the
identical procedure, "no plaintext found" could just mean the grep was wrong.

**Verdict:** pages and WAL frames are both ciphertext, so shred lever 2 covers replicated
WAL segments. **Still unverified:** that Litestream adds no plaintext framing of its own
around those frames. Install litestream and re-check before claiming the S3 objects are
wholly opaque.

## 3. What does a pull-model feed cost? — it depends entirely on one number

`probes/checkout/run.exs`. Reads one row from each of N different users' cells, which is
the pull-model feed reduced to its essential shape.

```
mix run probes/checkout/run.exs 50
SHROUD_MAX_RESIDENT=256 mix run probes/checkout/run.exs 200
```

| N | max_resident | warm feed | p50/cell | attributable to checkout | cold penalty |
|---|---|---|---|---|---|
| 10 | 64 | 1.1 ms | 108 µs | ~0 | 30.9 ms |
| 50 | 64 | 5.1 ms | 100 µs | 0.5 ms (10%) | 58.7 ms |
| 200 | 64 | **147.1 ms** | **701 µs** | 128.1 ms (87%) | 22.6 ms |
| 200 | 256 | **16.6 ms** | **79 µs** | 1.9 ms (12%) | 126.5 ms |

### The finding

**Pull is not slow. Thrashing is slow.** The same 200-profile feed is 147 ms or 16.6 ms —
a 8.9× swing — with no change but the resident-cell cap. Below the cap, a cell checkout
costs single-digit microseconds and is ~10% of a feed read; above it, every read evicts a
cell somebody else is about to want and checkout becomes 87% of the work.

So the design rule is not "avoid fan-out". It is:

> **`max_resident` must exceed the working set of a feed page.** A feed of N profiles
> needs headroom for N resident cells, plus whatever else the node is serving.

That reframes the pull-vs-push question in `prd.md`. Push was specified as insurance
against fan-out being inherently expensive. It is not — 200 cells in 16.6 ms is fine.
**Pull stands, and `SharedBlob` stays unbuilt.** What replaces it as a real concern is
capacity planning: a node serving feeds needs a resident cap sized to concurrent feed
pages, and the failure mode when it is undersized is a cliff rather than a slope.

The cold column is the other half. A cold cell costs ~0.6 ms — open, SQLCipher key
derivation, migration check — so a first-ever feed page pays ~60 ms for 50 profiles. That
is a warmup problem, not a steady-state one, and it is also the shape a thundering herd
takes after node loss.

### Caveats, so these are not over-read

Single node, loopback, no lease contention, one row per cell, nothing else resident.
Cross-node routing and eviction churn under real concurrency are **not** measured and both
make it worse. The 16.6 ms figure is a floor, not a promise.
