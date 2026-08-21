# Shroud

A zero-knowledge profile app on AshCell. One encrypted SQLite cell per user, an
encryption key derived from a passkey inside the browser, per-audience sharing, and
account deletion that destroys key material instead of data.

X-shaped on the surface: a timeline, a composer, and a profile with a display name,
birthday and bio under per-field audience control. The interesting part is that the
server storing all of it cannot read most of it.

**Posts come in two kinds, and the interface never lets you forget which.** A post to
an audience is encrypted in your browser and reaches the server as ciphertext (🔒). A
public post is stored in the clear (🌐) — because "public" and "hidden from the server"
cannot both be true, and pretending otherwise would be theatre. The composer says which
one you are about to do, before you do it.

That split is not a compromise, it is the mechanism: public posts can be indexed and
ordered globally in Postgres *because* the server can read them, and private posts
cannot *because* it can't.

- [`docs/prd.md`](docs/prd.md) — the design, the threat model, and the tier split
- [`docs/probes.md`](docs/probes.md) — Stage 0 measurements, including the one that
  settled pull vs. push

## What this proves

**A passkey can carry an encryption key, not just a signature.** The WebAuthn `prf`
extension returns deterministic bytes for a fixed salt; HKDF turns them into a
key-encryption key that unwraps a master key. The server participates in
authentication and never sees the key material. Signatures cannot do this job — ECDSA
is non-deterministic, so "derive a key from the assertion" is a dead end, and this is
the standard way that design goes wrong.

**An offline user is not a storage problem.** Three sub-problems, three answers:
writing to them is a sealed box against their published ECDH key; reading their shared
data works off grants they pre-computed while online; and *server-side processing* of
their private data is genuinely impossible, which is why the tier split exists rather
than being papered over.

**Deletion can be instant and irreversible.** `Shroud.Shred.cryptoshred/1` deletes a
handful of rows — every wrapped copy of the master key — and every encrypted field in
that user's cell becomes permanently unreadable, with the cell file untouched so other
users' share edges still resolve. No rewriting, no backup sweep, no waiting.

**Per-user cells survive a real feed.** A 200-profile feed opens 200 SQLite files in
16.6 ms warm. The measured caveat is sharper than the headline; see below.

## What it measured, and the one number that matters

From [`docs/probes.md`](docs/probes.md), on this machine:

| N profiles | `max_resident` | warm feed | attributable to checkout |
|---|---|---|---|
| 50 | 64 | 5.1 ms | 10% |
| 200 | 64 | **147.1 ms** | 87% |
| 200 | 256 | **16.6 ms** | 12% |

**Pull is not slow; thrashing is slow.** The same feed is 8.9× slower with no change
but the resident-cell cap. Below the cap a checkout is a rounding error; above it,
every read evicts a cell another read is about to want.

So the design rule is not "avoid fan-out" — it is **`max_resident` must exceed the
working set of a feed page**. That inverted the PRD's open question: push (a global
table of pre-shared ciphertext) was specified as insurance against fan-out being
inherently expensive, and the measurement says it is not. Pull stands, push stays
unbuilt, and what replaces it as a live concern is capacity planning, where the failure
mode is a cliff rather than a slope.

## Where it stops

Honest limits, not future work:

- **This is not zero-trust.** The server ships the JavaScript that touches the master
  key, so a *malicious* server can exfiltrate keys on the next login. Same caveat as
  Proton Mail and the Bitwarden web vault. What you do get: a stolen disk, a leaked
  backup, a rogue DBA and a subpoena on the host all yield noise for Tier 1.
- **Tier 0 is readable by the server, by design.** Handles, audience membership, and
  "when did this profile last change" have to be queryable for the feed to sort and
  page at all. The metadata graph is not private here.
- **What you shared with Alice, Alice keeps.** Those content keys were wrapped to her
  key, never to yours, so shredding cannot reach them. Revocation stops future reads
  and cannot un-send what was already fetched. This is in the deletion UI, not just
  here.
- **PBKDF2, not Argon2id**, for the recovery passphrase — Argon2 needs a WASM bundle
  and WebCrypto has PBKDF2 natively. 600k iterations of PBKDF2-SHA512 is the OWASP
  figure and is weaker against GPU attack. A deliberate PoC compromise.
- **No searchable encryption**, so no server-side search over private posts or fields.
  No avatars: images would need client-side thumbnailing to avoid a server that must
  read them, which is a real design problem and out of scope. Monograms instead.
- **A private post goes to exactly one audience.** Posting the same thing to two
  audiences means two posts. Multi-audience would mean a wrap per audience per post,
  which is a schema change rather than a hard problem.
- **No likes, replies, or follows.** A reply to an encrypted post raises a genuine
  question — which audience's key does the reply use? — that deserves designing rather
  than guessing at.
- **PRF coverage is unverified.** `probes/prf/index.html` needs a human with a real
  authenticator, and has not been run. If PRF turns out to be thin across target
  browsers, the recovery passphrase stops being a fallback and becomes the primary
  path.
- **Litestream is not installed here**, so probe 2 verifies the claim underneath the
  Litestream one — that SQLCipher pages *and WAL frames* are ciphertext — rather than
  Litestream's own framing.
- Inherited from the workspace and unsolved: every deploy migrates every cell; fencing
  protects writes but not reads; background jobs have no request boundary to route at.

## Layout

```
lib/shroud/
  auth.ex            passkey ceremonies via Wax — and nothing to do with encryption
  sealing.ex         server-side sealed boxes: how a job writes to an offline user
  shred.ex           the three deletion levers, and what each one cannot reach
  profiles.ex        cross-cell reads: the timeline and the profile feed
  global/            Postgres, Tier 0: users, credentials, key wraps, audiences,
                     feed edges, post index
  profile/           per-user cell: fields, audiences, grants, inbox, posts
  cells/             cell schema migrations and the SQLCipher key vault
assets/js/shroud/
  crypto.js          the key hierarchy — the only file that touches plaintext keys
  session.js         the master key's only home, a module variable in one tab
  webauthn.js        the two ceremonies, and PRF evaluation
  hooks.js           LiveView bridge: server renders ciphertext, client decrypts
lib/shroud_web/live/
  timeline_live.ex   /home    — composer and timeline
  profile_live.ex    /profile — your encrypted details, and your posts
  people_live.ex     /people  — evidence page: one cell per person, timed
  settings_live.ex   /settings— audiences, membership, and deletion
probes/              Stage 0, run before any app code
```

## Running it

Requires SQLCipher, Postgres, and `direnv` (or exporting `.envrc` by hand — a missing
`EXQLITE_USE_SYSTEM` fails *silently* at dep-compile time and you get an unencrypted
database).

```sh
direnv allow          # or: source .envrc
mix setup
mix run priv/repo/seeds.exs
mix phx.server
```

Then open <http://localhost:4000> and create an account. You will need a real
authenticator — a platform passkey or a password manager that supports one.

### Two accounts, one feed

```
Browser A                              Browser B
---------                              ---------
create account @alice                  create account @bob
unlock (passkey)
/settings -> add audience "Friends"
          -> add @bob to Friends
/home     -> post "hello world" Public
          -> post "just for you" Friends
                                       unlock (passkey)
                                       /home -> sees both, one 🌐 one 🔒,
                                                the 🔒 decrypted in-tab
```

Then sign out of Browser B and reload `/home`: the public post still reads, the private
one shows *encrypted — unlock to read*. That is the whole app in one screen.

The right-hand rail on `/home` reports how many cells the server opened to assemble the
page and how many of the posts it could actually read — usually a small fraction.

Bob's feed shows Alice because Alice put him in an audience and shared a field with
it. It is not mutual — Alice sees nothing of Bob's until Bob does the same. Alice can
be signed out, her cell closed, her master key nowhere on the machine, and Bob's feed
still works: the grant was computed when she shared, not when he read.

Two different browsers on one machine is enough (each has its own passkey store).
Two *devices* would need a shared origin, and `rp_id` is `localhost` here.

**You will authenticate twice on arrival, and once per page load.** That is the design,
not a bug: the master key lives in a JavaScript variable in one tab, so a document load
loses it. Sign-in has to be a full load — it crosses a `live_session` boundary and the
socket's session predates the auth cookie — so you land on `/profile` locked and unlock
there. After that, moving between profile, feed and settings is client-side navigation
and the key survives. Caching it in `sessionStorage` would remove the second prompt and
weaken the only property the app has; that trade was declined.

The seeded users (`@ada`, `@grace`, …) have public keys but no passkeys, so they cannot
sign in — they exist to give you someone to add to an audience. Their private keys were
discarded at seed time, so nothing sealed to them is ever readable, which is itself a
demonstration that a lost key is not recoverable.

### Seeing the claim rather than taking it on faith

```sh
# The plaintext is not in the cell file, nor in the HTML. Proven by test:
mix test test/zero_knowledge_test.exs test/posts_test.exs

# The browser crypto and the Elixir crypto actually agree (needs node):
./test/js/run.sh

# What the feed costs, at your own N:
SHROUD_MAX_RESIDENT=256 mix run probes/checkout/run.exs 200

# Whether SQLCipher's WAL frames really are opaque:
./probes/ciphertext/probe.sh
```

Or open the network inspector while editing your profile. The websocket frames carry
base64 and the server has no way to read it — which is easier to believe once you have
watched it happen.
