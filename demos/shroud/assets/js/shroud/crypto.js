// The key hierarchy, entirely in the browser.
//
// Nothing in this file may send anything anywhere. It produces and consumes opaque
// blobs; the LiveView hooks move them. That split is deliberate — it keeps the set
// of places a plaintext key could escape down to one small, readable file.
//
// Every primitive here is native WebCrypto, which is a constraint that shaped the
// choices rather than the other way round:
//
//   AES-256-GCM      content + key wrapping   (WebCrypto has no ChaCha20 at all)
//   ECDH P-256       sealing to a public key  (WebCrypto's X25519 support is patchy)
//   HKDF-SHA256      PRF output      -> KEK
//   PBKDF2-SHA512    passphrase      -> KEK
//
// PBKDF2 is the one real compromise: Argon2id is meaningfully better against GPU
// attack, but needs a WASM bundle. 600k iterations of PBKDF2-SHA512 is the OWASP
// figure and is defensible for a PoC. It is recorded as a known deviation in
// docs/prd.md rather than quietly swapped.

const KDF_INFO = "shroud.kek.v1";
const PRF_SALT = new TextEncoder().encode("shroud.v1");
const PBKDF2_ITERATIONS = 600000;

// ---------------------------------------------------------------- encoding

export const b64 = (buf) => {
  const bytes = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
};

export const unb64 = (str) => {
  const s = atob(str);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
};

const randomBytes = (n) => crypto.getRandomValues(new Uint8Array(n));
const utf8 = (s) => new TextEncoder().encode(s);
const fromUtf8 = (buf) => new TextDecoder().decode(buf);

// ---------------------------------------------------------------- KEKs
//
// A KEK only ever wraps and unwraps other keys, so it is created non-extractable.
// If a bug tries to exfiltrate one, WebCrypto refuses rather than obliging.

export async function kekFromPrf(prfOutput) {
  const ikm = await crypto.subtle.importKey("raw", prfOutput, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: utf8(KDF_INFO) },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function kekFromPassphrase(passphrase, saltB64, iterations) {
  const material = await crypto.subtle.importKey("raw", utf8(passphrase), "PBKDF2", false, [
    "deriveKey",
  ]);
  return crypto.subtle.deriveKey(
    {
      name: "PBKDF2",
      hash: "SHA-512",
      salt: unb64(saltB64),
      iterations: iterations || PBKDF2_ITERATIONS,
    },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export const passphraseParams = () => ({
  kdf_salt: b64(randomBytes(16)),
  kdf_iterations: PBKDF2_ITERATIONS,
});

// ---------------------------------------------------------------- master key
//
// MK is held as raw bytes rather than a CryptoKey because it is used two ways: as
// an AES key to wrap other keys, and as HKDF input material. A single CryptoKey
// cannot do both, and re-importing per use is cheap.

export const generateMasterKey = () => randomBytes(32);

export async function wrapBytes(kek, bytes) {
  const iv = randomBytes(12);
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, kek, bytes);
  return { wrapped_key: b64(ciphertext), iv: b64(iv) };
}

export async function unwrapBytes(kek, wrappedB64, ivB64) {
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: unb64(ivB64) },
    kek,
    unb64(wrappedB64),
  );
  return new Uint8Array(plain);
}

const asAesKey = (raw) =>
  crypto.subtle.importKey("raw", raw, { name: "AES-GCM", length: 256 }, false, [
    "encrypt",
    "decrypt",
  ]);

// ---------------------------------------------------------------- content keys
//
// One content key per field. This is what makes per-field audience choice free:
// sharing a birthday with Family and a name with Public is two independent wraps,
// never a re-encryption.

export const generateContentKey = () => randomBytes(32);
export const generateGroupKey = () => randomBytes(32);

export async function encryptField(contentKeyRaw, plaintext) {
  const key = await asAesKey(contentKeyRaw);
  const iv = randomBytes(12);
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, utf8(plaintext));
  return { ciphertext: b64(ciphertext), iv: b64(iv) };
}

export async function decryptField(contentKeyRaw, ciphertextB64, ivB64) {
  const key = await asAesKey(contentKeyRaw);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: unb64(ivB64) },
    key,
    unb64(ciphertextB64),
  );
  return fromUtf8(plain);
}

// Wrapping a raw key under another raw key. Used for MK -> group key and
// group key -> content key, which are the same operation at two levels.
export async function wrapUnder(outerRaw, innerRaw) {
  return wrapBytes(await asAesKey(outerRaw), innerRaw);
}

export async function unwrapUnder(outerRaw, wrappedB64, ivB64) {
  return unwrapBytes(await asAesKey(outerRaw), wrappedB64, ivB64);
}

// ---------------------------------------------------------------- identity keys
//
// An ECDH P-256 pair per user. The public half is published, which is the entire
// mechanism behind writing to an offline user: anyone can derive a shared secret
// to them, nobody can derive one *from* them without the private half, and the
// private half is wrapped under MK.

export async function generateIdentityKeyPair() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ]);
  const publicKey = await crypto.subtle.exportKey("spki", pair.publicKey);
  const privateKey = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  return { publicKey: b64(publicKey), privateKeyBytes: new Uint8Array(privateKey) };
}

const importPublic = (spkiB64) =>
  crypto.subtle.importKey("spki", unb64(spkiB64), { name: "ECDH", namedCurve: "P-256" }, false, []);

const importPrivate = (pkcs8) =>
  crypto.subtle.importKey("pkcs8", pkcs8, { name: "ECDH", namedCurve: "P-256" }, false, [
    "deriveBits",
  ]);

async function sharedKey(privateKey, publicKey) {
  const bits = await crypto.subtle.deriveBits(
    { name: "ECDH", public: publicKey },
    privateKey,
    256,
  );
  const ikm = await crypto.subtle.importKey("raw", bits, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(32), info: utf8("shroud.seal.v1") },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

// Seal bytes to somebody's published public key, using a throwaway pair. The
// ephemeral public key travels with the ciphertext; the ephemeral private key is
// never stored, so nothing retained can re-derive this shared secret afterwards.
export async function sealTo(recipientPublicKeyB64, bytes) {
  const ephemeral = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits",
  ]);
  const key = await sharedKey(ephemeral.privateKey, await importPublic(recipientPublicKeyB64));
  const iv = randomBytes(12);
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, bytes);
  const epk = await crypto.subtle.exportKey("spki", ephemeral.publicKey);
  return {
    ciphertext: b64(ciphertext),
    iv: b64(iv),
    ephemeral_public_key: b64(epk),
  };
}

export async function openSealed(privateKeyBytes, sealed) {
  const key = await sharedKey(
    await importPrivate(privateKeyBytes),
    await importPublic(sealed.ephemeral_public_key),
  );
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: unb64(sealed.iv) },
    key,
    unb64(sealed.ciphertext),
  );
  return new Uint8Array(plain);
}

export { PRF_SALT, PBKDF2_ITERATIONS };
