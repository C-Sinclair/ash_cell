// The master key's only home for the duration of a session.
//
// It lives in a module-scoped variable — deliberately not localStorage,
// sessionStorage, or IndexedDB. Persisting it would mean a key at rest on the
// device protected by nothing, which throws away most of what the passkey bought:
// the point of PRF is that unlocking requires the authenticator and a user gesture,
// so caching past that gesture reintroduces exactly the risk it removes.
//
// The cost is a passkey prompt on every page load. That is the correct trade for a
// PoC whose entire claim is about key custody, and the honest version of a decision
// that most apps quietly make the other way.

import * as c from "./crypto.js";

let masterKey = null;      // Uint8Array(32)
let identityKey = null;    // Uint8Array, pkcs8
let groupKeys = new Map(); // audience slug -> Uint8Array(32)

export const locked = () => masterKey === null;

export function unlock(mk, identityPrivateKeyBytes) {
  masterKey = mk;
  identityKey = identityPrivateKeyBytes || null;
  groupKeys = new Map();
}

export function lock() {
  // Overwrite before dropping. Not a strong guarantee — the JS engine may have
  // copied these bytes during GC and we cannot reach those copies — but it
  // shortens the window in which a heap snapshot would find the key intact.
  if (masterKey) masterKey.fill(0);
  if (identityKey) identityKey.fill(0);
  for (const k of groupKeys.values()) k.fill(0);
  masterKey = null;
  identityKey = null;
  groupKeys = new Map();
}

function requireKey() {
  if (!masterKey) throw new Error("shroud: session is locked; unlock before touching Tier 1 data");
  return masterKey;
}

export const mk = requireKey;
export const identity = () => identityKey;

// ---------------------------------------------------------------- group keys

export async function groupKeyFor(slug, wrapped) {
  if (groupKeys.has(slug)) return groupKeys.get(slug);
  const raw = await c.unwrapUnder(requireKey(), wrapped.wrapped_group_key, wrapped.iv);
  groupKeys.set(slug, raw);
  return raw;
}

export async function newGroupKey(slug) {
  const raw = c.generateGroupKey();
  groupKeys.set(slug, raw);
  const wrapped = await c.wrapUnder(requireKey(), raw);
  return { raw, wrapped_group_key: wrapped.wrapped_key, iv: wrapped.iv };
}

export function cacheGroupKey(slug, raw) {
  groupKeys.set(slug, raw);
}

// ---------------------------------------------------------------- fields

// Encrypt a field under a fresh content key, and wrap that content key for each
// audience it is shared with. The owner's own copy is wrapped under MK so they can
// still read their own field — easy to forget, and the symptom is a user locked out
// of data they just wrote.
export async function sealField(key, plaintext, audiences) {
  const contentKey = c.generateContentKey();
  const { ciphertext, iv } = await c.encryptField(contentKey, plaintext);
  const ownWrap = await c.wrapUnder(requireKey(), contentKey);

  const grants = [];
  for (const [slug, groupKeyRaw] of audiences) {
    const w = await c.wrapUnder(groupKeyRaw, contentKey);
    grants.push({
      field_key: key,
      audience_slug: slug,
      wrapped_content_key: w.wrapped_key,
      iv: w.iv,
    });
  }

  return {
    field: { key, ciphertext, iv, content_key_id: c.b64(contentKey.slice(0, 8)) },
    own_wrap: { wrapped_content_key: ownWrap.wrapped_key, iv: ownWrap.iv },
    grants,
  };
}

export async function openOwnField(field, ownWrap) {
  const contentKey = await c.unwrapUnder(requireKey(), ownWrap.wrapped_content_key, ownWrap.iv);
  return c.decryptField(contentKey, field.ciphertext, field.iv);
}

// Reading somebody else's field: unwrap the content key with the group key we hold
// for the audience they shared it with. The owner is not involved and need not be
// online — their grant was computed at share time and has been sitting there since.
export async function openSharedField(field, grant, groupKeyRaw) {
  const contentKey = await c.unwrapUnder(groupKeyRaw, grant.wrapped_content_key, grant.iv);
  return c.decryptField(contentKey, field.ciphertext, field.iv);
}

// ---------------------------------------------------------------- posts

// A private post gets a fresh content key wrapped twice: once under the audience's
// group key for readers, and once under MK for the author. Both are required. Omitting
// the author's wrap ships a post its own author cannot read back, which is an easy bug
// to write and a baffling one to be on the receiving end of.
export async function sealPost(body, audienceSlug, groupKeyRaw) {
  const contentKey = c.generateContentKey();
  const { ciphertext, iv } = await c.encryptField(contentKey, body);
  const readerWrap = await c.wrapUnder(groupKeyRaw, contentKey);
  const ownWrap = await c.wrapUnder(requireKey(), contentKey);

  return {
    visibility: audienceSlug,
    ciphertext,
    iv,
    content_key_id: c.b64(contentKey.slice(0, 8)),
    wrapped_content_key: readerWrap.wrapped_key,
    wrap_iv: readerWrap.iv,
    own_wrapped_content_key: ownWrap.wrapped_key,
    own_wrap_iv: ownWrap.iv,
  };
}

// Opens a private post from whichever direction the reader is coming from: their own
// post via MK, or somebody else's via the group key sealed to them when they joined.
export async function openPost(post, identityPrivateKey) {
  if (post.own_wrap) {
    const contentKey = await c.unwrapUnder(
      requireKey(),
      post.own_wrap.wrapped_content_key,
      post.own_wrap.iv,
    );
    return c.decryptField(contentKey, post.ciphertext, post.iv);
  }

  if (!post.grant || !post.membership) throw new Error("no grant for this post");
  if (!identityPrivateKey) throw new Error("identity key unavailable");

  const groupKey = await c.openSealed(identityPrivateKey, {
    ciphertext: post.membership.wrapped_group_key,
    iv: post.membership.iv,
    ephemeral_public_key: post.membership.ephemeral_public_key,
  });

  const contentKey = await c.unwrapUnder(
    groupKey,
    post.grant.wrapped_content_key,
    post.grant.iv,
  );
  return c.decryptField(contentKey, post.ciphertext, post.iv);
}
