// WebAuthn ceremonies, and the PRF evaluation that turns one into a key.
//
// Two jobs share one user gesture. The assertion goes to the server to prove
// identity; the PRF output stays here and becomes a KEK. The server sees the first
// and never the second — if PRF bytes ever end up in a fetch body, that is a bug.

import * as c from "./crypto.js";

const b64url = (buf) => c.b64(buf).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64url = (s) => c.unb64(s.replace(/-/g, "+").replace(/_/g, "/"));

export class NoPrfError extends Error {
  constructor() {
    super("authenticator did not return PRF output");
    this.name = "NoPrfError";
  }
}

async function post(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": document.querySelector("meta[name='csrf-token']").content,
    },
    body: JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(json.error || `request to ${path} failed`);
  return json;
}

function decodeOptions(opts) {
  const out = { ...opts, challenge: fromB64url(opts.challenge) };
  if (opts.user) out.user = { ...opts.user, id: fromB64url(opts.user.id) };
  if (opts.allowCredentials && opts.allowCredentials.length) {
    out.allowCredentials = opts.allowCredentials.map((cr) => ({
      ...cr,
      id: fromB64url(cr.id),
    }));
  } else {
    delete out.allowCredentials;
  }
  return out;
}

// ---------------------------------------------------------------- registration

export async function register(handle, passphrase) {
  const { options } = await post("/auth/registration_options", { handle });

  const credential = await navigator.credentials.create({
    publicKey: decodeOptions(options),
  });

  const prf = credential.getClientExtensionResults()?.prf?.results?.first;

  // PRF may only be available on assertion, not at creation, depending on the
  // authenticator. So a missing value here is not fatal: register with the
  // passphrase wrap, and let the first login add the PRF wrap once we can get one.
  const mk = c.generateMasterKey();
  const identity = await c.generateIdentityKeyPair();

  const wraps = [];

  const kdf = c.passphraseParams();
  const passKek = await c.kekFromPassphrase(passphrase, kdf.kdf_salt, kdf.kdf_iterations);
  const passWrap = await c.wrapBytes(passKek, mk);
  wraps.push({ kind: "passphrase", ...passWrap, ...kdf });

  if (prf) {
    const prfKek = await c.kekFromPrf(prf);
    const prfWrap = await c.wrapBytes(prfKek, mk);
    wraps.push({
      kind: "prf",
      ...prfWrap,
      credential_id: b64url(credential.rawId),
    });
  }

  // The identity private key is wrapped under MK and stored as a field in the
  // user's own cell, not here — it is Tier 1 data like any other.
  const wrappedIdentity = await c.wrapUnder(mk, identity.privateKeyBytes);

  // A default audience, created here because it cannot be created anywhere else: a
  // group key has to be wrapped under MK, and MK exists only in this browser. Without
  // it a new account lands on a dead end — an empty audience list means there is
  // nowhere to add anyone, so the first thing a new user can do is nothing.
  const groupKey = c.generateGroupKey();
  const wrappedGroupKey = await c.wrapUnder(mk, groupKey);

  await post("/auth/register", {
    handle,
    attestation_object: b64url(credential.response.attestationObject),
    client_data_json: new TextDecoder().decode(credential.response.clientDataJSON),
    public_key: identity.publicKey,
    wraps,
    wrapped_identity: {
      ciphertext: wrappedIdentity.wrapped_key,
      iv: wrappedIdentity.iv,
    },
    audience: {
      slug: "friends",
      name: "Friends",
      wrapped_group_key: wrappedGroupKey.wrapped_key,
      iv: wrappedGroupKey.iv,
    },
  });

  return { mk, identityPrivateKeyBytes: identity.privateKeyBytes, prfAvailable: !!prf };
}

// ---------------------------------------------------------------- login

export async function login(passphrase) {
  const { options } = await post("/auth/authentication_options", {});

  const assertion = await navigator.credentials.get({
    publicKey: { ...decodeOptions(options), extensions: { prf: { eval: { first: c.PRF_SALT } } } },
  });

  const prf = assertion.getClientExtensionResults()?.prf?.results?.first;

  const { user, wraps, wrapped_identity } = await post("/auth/authenticate", {
    credential_id: b64url(assertion.rawId),
    auth_data: b64url(assertion.response.authenticatorData),
    signature: b64url(assertion.response.signature),
    client_data_json: new TextDecoder().decode(assertion.response.clientDataJSON),
  });

  const mk = await unwrapMasterKey(wraps, prf, passphrase);

  let identityPrivateKeyBytes = null;
  if (wrapped_identity) {
    identityPrivateKeyBytes = await c.unwrapUnder(
      mk,
      wrapped_identity.ciphertext,
      wrapped_identity.iv,
    );
  }

  return { user, mk, identityPrivateKeyBytes, prf };
}

// Try PRF first because it needs no typing, and fall back to the passphrase. A
// user with no PRF wrap yet — registered on a platform that only produces PRF at
// assertion time — takes the passphrase path and can then be upgraded.
async function unwrapMasterKey(wraps, prf, passphrase) {
  const prfWrap = wraps.find((w) => w.kind === "prf");

  if (prf && prfWrap) {
    try {
      const kek = await c.kekFromPrf(prf);
      return await c.unwrapBytes(kek, prfWrap.wrapped_key, prfWrap.iv);
    } catch (_) {
      // A PRF wrap that will not open means the authenticator produced different
      // bytes than at registration — a different credential, or a reset. Fall
      // through rather than failing the login outright.
    }
  }

  const passWrap = wraps.find((w) => w.kind === "passphrase");
  if (!passWrap) throw new NoPrfError();
  if (!passphrase) throw new Error("passphrase required: no usable PRF wrap for this authenticator");

  const kek = await c.kekFromPassphrase(passphrase, passWrap.kdf_salt, passWrap.kdf_iterations);
  return c.unwrapBytes(kek, passWrap.wrapped_key, passWrap.iv);
}

export { b64url, fromB64url };
