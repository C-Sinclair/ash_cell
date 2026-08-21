# Shroud — a zero-knowledge profile app on AshCell

A PoC. One encrypted SQLite cell per user, passkey-derived keys the server never sees,
per-audience sharing, and cryptoshredding on account deletion.

## What this proves

1. A passkey can carry an encryption key (WebAuthn `prf`), not just a signature, and the
   server can run a full social read/write app while holding only ciphertext for the
   fields that matter.
2. Account deletion can be *instant and irreversible* by destroying key material rather
   than data — a handful of row deletes, no rewriting of anything.
3. What a per-user-cell architecture actually costs when a feed has to read fifty
   different users' cells. This is the number the PoC exists to produce.

## Non-goals

- **Not zero-trust.** The server ships the JavaScript that touches the master key, so a
  malicious server can exfiltrate keys on the next login. Same caveat as Proton Mail and
  the Bitwarden web vault. What we get: a stolen disk, a leaked backup, a rogue DBA, and
  a subpoena on the host all yield noise for Tier 1 data. That is real and worth having;
  it is not what "zero trust" promises, and we will not claim it.
- **Not a compliance play.** Per repo policy: no HIPAA/physical-isolation claims, no
  confidential-computing framing.
- Not searchable encryption. No server-side search over Tier 1.
- Not multi-device key sync beyond the recovery passphrase.
- Not production auth (no rate limiting, no email verification, no session hardening
  beyond what Phoenix gives us).

## Threat model

| Adversary | Tier 0 | Tier 1 |
|---|---|---|
| Stolen disk / leaked backup / S3 snapshot | Protected (SQLCipher) | Protected (SQLCipher + E2E) |
| Rogue DBA, live SQL access | **Readable** | Protected |
| Compromised app server, passive | **Readable** | Protected for sessions not observed |
| Compromised app server, active (malicious JS) | Readable | **Broken** — accepted, documented |
| Another user | Per share grants | Per share grants |
| The user's own lost device | n/a | Recoverable via passphrase |

## Two data tiers

Encrypting everything produces an app that cannot do anything. So the tier is a schema
decision, made explicitly per field.

**Tier 0 — server-visible.** SQLCipher at rest, server holds the key. Usernames,
audience membership, share edges, timestamps, foreign keys, `updated_at`. Queryable,
sortable, indexable. This is what makes the feed possible.

**Tier 1 — end-to-end.** Opaque ciphertext columns. Display name, birthday, bio, avatar.
Addressable by *identity* (whose row is this), never by *content*.

Anything the feed filters or sorts by must be Tier 0. That is not a limitation of the
crypto — it is the same denormalisation the workspace already requires for
cross-data-layer relationships (`load` only, no cross-boundary filter or sort).

## Key hierarchy

```
passkey PRF(salt="shroud.v1") ──HKDF-SHA256──> KEK_prf   ──AES-GCM-unwrap──┐
recovery passphrase ──Argon2id(t=3,m=64MiB)──> KEK_pass  ──AES-GCM-unwrap──┼──> MK
additional device passkey ────────────────────> KEK_dev  ──AES-GCM-unwrap──┘

MK ──unwraps──> SK_user   (X25519 private; PK_user is public, in the global repo)
MK ──wraps────> GK_audience  (one per audience)
GK ──wraps────> CK_field     (one per profile field)
CK ──encrypts─> the Tier 1 ciphertext (XChaCha20-Poly1305)
```

- **MK** — 32 random bytes, generated in the browser at signup, never transmitted. Lives
  in a JS closure variable for the session. Not `localStorage`, not `sessionStorage`, not
  the LiveView process.
- **Every wrap of MK lives in the global repo.** Deleting all of them is the shred.
- **The cell's SQLCipher key is server-held** (KMS/master secret + tenant id) and is
  *deliberately unrelated to MK*. Deriving it from MK would mean the server cannot open
  the cell while the user is offline, which breaks writes-to-offline-users, all sharing,
  and every Tier 0 query. Explicit non-goal.

### Primitives: what WebCrypto forced

The PRD originally specified XChaCha20-Poly1305, X25519 and Argon2id. All three changed
during implementation, because the counterpart of every operation is native WebCrypto and
a WASM bundle for a PoC is not worth the weight:

| Purpose | Specified | Built | Why |
|---|---|---|---|
| Content + key wrapping | XChaCha20-Poly1305 | **AES-256-GCM** | WebCrypto has no ChaCha20 at all |
| Key agreement | X25519 | **ECDH P-256** | WebCrypto's X25519 support is patchy; P-256 is universal |
| PRF → KEK | HKDF-SHA256 | unchanged | native on both sides |
| Passphrase → KEK | Argon2id | **PBKDF2-SHA512, 600k** | Argon2 needs WASM; PBKDF2 is native |

**PBKDF2 is a real downgrade** and is recorded as such rather than swapped quietly: it is
meaningfully weaker than Argon2id against GPU attack. 600k iterations of PBKDF2-SHA512 is
the OWASP figure. Revisit with a WASM Argon2id before this is anything but a PoC.

Interop is the part that bites. `Shroud.Sealing` must match `assets/js/shroud/crypto.js`
byte for byte — SPKI DER for public keys, the GCM tag appended to the ciphertext, HKDF
hand-rolled because `:crypto` has HMAC but not HKDF — and a mismatch is a silent
decryption failure rather than an error. Hence `test/sealing_test.exs`.

### Why the indirection through audience keys

Sharing one field with 500 followers must not be 500 wraps. An audience (Friends, Family,
Public) has a `GK`, wrapped once per member. Sharing a field to an audience is one wrap of
its `CK` under `GK`. Adding a member is one wrap of `GK`. Per-field granularity falls out
free because each field is its own row with its own `CK`.

Removing a member rotates `GK` and re-wraps for the remainder. That is the one expensive
operation, and it is expensive in every design.

## Auth: Wax and the crypto are independent

Wax proves *who*. PRF provides *the key*. The two only meet in the browser.

- **Registration.** Wax ceremony → credential public key stored in global repo. Same
  assertion carries `prf.eval`; the browser derives `KEK_prf`, generates `MK` and
  `SK_user`, and POSTs back only: wrapped MK, `PK_user`, and the passphrase-wrapped MK.
- **Login.** Wax assertion with `prf.eval` → server gets authentication, browser gets 32
  bytes → unwrap MK → hold for session.
- The server never receives PRF output. If it ever appears in a request body, that is a bug.

## The offline problem, split three ways

**Writing to an offline user.** Seal to `PK_user` (HPKE / X25519 + XChaCha20-Poly1305).
Anyone, including the server and background jobs, can write to a user they cannot read.
The user decrypts on next login.

**Reading an offline user's shared data.** Grants are pre-computed while the owner is
online. The owner's presence at read time is irrelevant — the wrapped `CK` is already
sitting in their cell. This is the whole reason the audience-key graph exists.

**The server processing Tier 1 with nobody online.** Genuinely impossible. Thumbnails are
generated in the browser at upload time and encrypted alongside the full image. Anything
else that wants server-side processing of a field is an argument for moving that field to
Tier 0, and the PRD should say which tier and why.

## Data model

### Global repo (Postgres) — its own repo module

`Shroud.Global.Repo` must be a **separate repo module** from the cells'. Ecto's dynamic
binding is per repo *module*; a global resource sharing the cells' module would silently
inherit whatever tenant binding is ambient and write rows into a random user's database.

| Resource | Tier | Notes |
|---|---|---|
| `User` | 0 | id, handle, `inserted_at`, `shredded_at` |
| `Credential` | 0 | Wax credential id, COSE public key, sign count |
| `KeyWrap` | 0 | `user_id`, kind (`:prf` \| `:passphrase` \| `:device`), wrapped MK, salt. **Deleting every row for a user is the shred.** |
| `PublicKey` | 0 | `user_id`, `PK_user` — how anyone writes to an offline user |
| `AudienceMember` | 0 | `owner_id`, `audience_id`, `member_id` — how the feed finds candidates without opening cells |
| `FeedEdge` | 0 | denormalised `(viewer_id, owner_id, updated_at)` so the feed can sort and page in Postgres |

### Per-user cell (SQLite + SQLCipher)

| Resource | Tier | Notes |
|---|---|---|
| `ProfileField` | mixed | `key` (Tier 0: `"display_name"`), `ciphertext`+`nonce` (Tier 1), `updated_at` (Tier 0) |
| `Audience` | 0 | name, wrapped `GK` under MK |
| `FieldGrant` | 0 | `field_id`, `audience_id`, `CK` wrapped under `GK` |
| `Inbox` | 1 | payloads sealed to `PK_user` by others while offline |

Avatar bytes go to AshCell's object store, encrypted client-side; the cell holds the
pointer and the wrapped `CK`.

## Read model: pull, with push as a derived cache

**Confidentiality does not depend on where ciphertext lives — only on where key material
lives.** Alice's encrypted display name is noise to the server whether it sits in her cell
or in Postgres. Keys stay in cells; opaque bytes may be copied anywhere convenient. That is
what makes a push variant possible at all, and it is why the client-side crypto is
byte-identical under either model.

### Pull (what we build)

1. Page `FeedEdge` in Postgres — ordered, indexed, cheap. Yields fifty `owner_id`s.
2. For each owner, open their cell and read `ProfileField` rows plus the `FieldGrant`
   rows for audiences Bob belongs to.
3. Render ciphertext into the DOM as data attributes. A JS hook decrypts in place.

Step 2 is fifty cell checkouts, each subject to ownership, leases, and possible cross-node
routing. This is the honest cost of the architecture and the reason the PoC exists.

The LiveView pattern this implies: the server renders ciphertext, the client decrypts.
LiveView diffs opaque blobs perfectly well, and the decryption hook is idempotent.

### Push (the fallback, specified but not built)

At share time the owner also writes the opaque bytes to a global table:

```
SharedBlob{owner_id, field_key, ciphertext, audience_id,
           CK wrapped under GK_audience, updated_at}
```

The feed becomes one indexed query: `AudienceMember ⋈ SharedBlob`, sorted and paged in
Postgres, with zero cell opens. Bob decrypts exactly as before — he already holds
`GK_audience`, wrapped to his public key on his `AudienceMember` row.

**The fan-out is per-audience, not per-recipient.** Because `CK` is wrapped under `GK`,
which every member already holds, a push is *one row per (field, audience)* — Alice with
4 fields and 3 audiences writes at most 12 rows whether she has 5 friends or 50,000. This
is a side effect of a choice made for crypto reasons, and it is what makes push tractable
here when classic fan-out would not be.

A third variant — pushing into each recipient's cell — would cost 500 cell opens per edit.
Rejected: worst write cost of the three, and the offline-first property it buys is not
something this PoC tests.

### Trade-offs

| | Pull | Push |
|---|---|---|
| Feed read, 50 profiles | 50 cell opens + leases + possible cross-node hops | 1 indexed Postgres query |
| Write on edit | 1 cell write | 1 cell write + 1 Postgres write per audience |
| Source of truth | Cell, only | Cell, with a derived copy |
| Rotating `GK` (removing a member) | Re-wrap grants in one cell | Re-wrap **and** re-push every blob for that audience |
| Consistency | Trivially correct | Cell and Postgres can diverge |
| Shred lever 1 (destroy MK wraps) | Unaffected | Unaffected |
| Shred lever 2 (destroy cell key) | Revokes shared data too | **Copies outside the cell survive** |

**`SharedBlob` is a cache, never a second source of truth.** A transaction cannot span a
cell and Postgres — the same constraint that forbids spanning two cells — so the two writes
cannot be atomic. Rather than an outbox and a distributed-transaction repair path, treat
the table as derived from cells and rebuildable from them. Then divergence is a stale cache
entry, and recovery is "re-derive from the cell." This framing is a precondition for
building push at all.

**Push weakens shred lever 2.** In pull, destroying the cell key takes the `FieldGrant`s
with it, so a recipient loses access despite holding `GK`. Pushed copies live in Postgres
and survive. This does not change what we promise recipients — "what you shared with Alice,
Alice keeps" holds in both models, because the grant chain to a recipient never routes
through the owner's MK — but lever 2 would need to sweep `SharedBlob` explicitly.

### The measurement decided it: pull

Run, not estimated. Full numbers in [`probes.md`](probes.md); the headline:

| N | `max_resident` | warm feed | attributable to checkout |
|---|---|---|---|
| 50 | 64 | 5.1 ms | 10% |
| 200 | 64 | **147.1 ms** | 87% |
| 200 | 256 | **16.6 ms** | 12% |

**Pull is not slow. Thrashing is slow.** The same 200-profile feed is 8.9× slower with no
change but the resident-cell cap.

This inverts the question this section used to pose. Push was specified as insurance
against fan-out being inherently expensive, and it is not — 200 cells in 16.6 ms is fine.
So **pull stands and `SharedBlob` stays unbuilt.** The concern it was insurance against is
replaced by a different one:

> **`max_resident` must exceed the working set of a feed page.** A feed of N profiles needs
> headroom for N resident cells plus whatever else the node serves. Undersize it and the
> failure mode is a cliff, not a slope.

Cold cells cost ~0.6 ms each — open, SQLCipher key derivation, migration check — so a
first-ever page pays ~60 ms for 50 profiles. A warmup problem, and also the shape a
thundering herd takes after node loss.

Not measured, and both make it worse: cross-node routing, and eviction churn under real
concurrency. The 16.6 ms figure is a floor, not a promise.

## Cryptoshredding

Three independent levers, in increasing bluntness:

1. **Destroy every `KeyWrap` row for the user.** MK is unrecoverable; every Tier 1 blob in
   the cell is noise *while the cell file stays intact*, so other users' share edges and
   audience memberships still resolve. One transaction, a few row deletes, instant,
   irreversible. **This is what account deletion does.**
2. **Destroy the cell key.** File, WAL, and every Litestream segment become noise together.
   Blunter — takes out Tier 0 rows others reference.
3. **Delete the file.** Garbage collection, not a security boundary. Which is precisely why
   deferring it is safe.

Litestream replicates SQLCipher-encrypted pages, so lever 2 should cover the S3 history —
**to be confirmed by probe before we claim it.**

### The caveat that belongs in the UI, not a footnote

**What you shared with Alice, Alice keeps.** Those content keys were wrapped to her key,
not yours; shredding your MK does not touch them. Same for revocation: rotating `GK`
stops future reads, and cannot un-see what she already fetched. The deletion screen says
this in plain words.

## Staging

| Stage | Deliverable | Gate |
|---|---|---|
| 0 | Probes: PRF in target browsers; Litestream segments are ciphertext; cost of N cell checkouts | **2 of 3 done**; PRF needs a human. `docs/probes.md` |
| 1 | Phoenix app, global repo (separate module), AshCell wired, cells provisioning | `mix test` green; a cell opens |
| 2 | Wax registration + login, no crypto | Round-trip a session |
| 3 | Key hierarchy in the browser: MK, wraps, passphrase recovery | MK survives logout/login on two devices |
| 4 | `ProfileField` write/read, own profile only, E2E encrypted | Server logs show no plaintext |
| 5 | Audiences, grants, viewing another user's profile | Bob reads Alice's field; Carol cannot |
| 6 | Feed over N profiles + instrumentation | **Done** — see the table above |
| 7 | Cryptoshredding + the honest UI | Blobs unreadable, cell intact, others' feeds still work |

## Open risks

- **PRF coverage** is the biggest external unknown; Stage 0 probe decides whether the
  passphrase path is a fallback or the primary.
- ~~Pull-model feed latency may force push.~~ **Resolved: it does not.** Replaced by a
  capacity concern — `max_resident` sized below a feed page turns a 16.6 ms feed into a
  147 ms one.
- **Fencing protects writes, not reads** (existing workspace limitation) — a partitioned
  node can serve a stale profile from a cell it no longer owns. Does not compromise
  confidentiality; does mean stale reads.
- **Every deploy migrates every cell**, and `fly-replay` does nothing for an open LiveView
  websocket. Inherited, unsolved, not hidden.
- **Background jobs have no request boundary to route at** — the inbox write path must go
  through explicit binding, never an inherited one.
- **AshSqlite has no aggregates.** No `count` of shared fields via an Ash aggregate;
  expression calculations only.
