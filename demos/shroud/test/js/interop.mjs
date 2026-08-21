// Interop between assets/js/shroud/crypto.js and Shroud.Sealing.
//
// This is the highest-risk surface in the app and the one unit tests on either side
// cannot cover: both implementations can be individually correct and still disagree,
// and the symptom is a decryption failure with no error to read. Every mismatch this
// guards against is a real one that had to be got right -- SPKI DER framing for public
// keys, the GCM tag appended rather than returned separately, HKDF salt and info bytes.
//
// Run via test/js/run.sh, which drives the Elixir half.

import * as c from "../../assets/js/shroud/crypto.js";
import { readFileSync, writeFileSync } from "node:fs";

const [, , command, path] = process.argv;
const read = () => JSON.parse(readFileSync(path, "utf8"));
const write = (o) => writeFileSync(path, JSON.stringify(o, null, 2));

let failures = 0;
const check = (label, ok) => {
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}`);
  if (!ok) failures++;
};

switch (command) {
  // Publish a JS-generated identity so Elixir can seal to it.
  case "keygen": {
    const { publicKey, privateKeyBytes } = await c.generateIdentityKeyPair();
    write({ public_key: publicKey, private_key: c.b64(privateKeyBytes) });
    break;
  }

  // Open what Elixir sealed to that identity.
  case "open": {
    const { private_key, sealed, expected } = read();
    const plain = await c.openSealed(c.unb64(private_key), sealed);
    const text = new TextDecoder().decode(plain);
    check(`Elixir -> JS: "${text}"`, text === expected);
    break;
  }

  // Seal to an Elixir-generated identity, for Elixir to open.
  case "seal": {
    const { public_key, plaintext } = read();
    const sealed = await c.sealTo(public_key, new TextEncoder().encode(plaintext));
    write({ sealed });
    break;
  }

  // The parts that never cross the boundary, checked here because this is the only
  // place the real browser code is executed at all.
  case "selftest": {
    console.log("JS-only key hierarchy:");

    // PRF -> KEK -> wrap/unwrap of a master key.
    const prf = crypto.getRandomValues(new Uint8Array(32));
    const kek = await c.kekFromPrf(prf);
    const mk = c.generateMasterKey();
    const wrapped = await c.wrapBytes(kek, mk);
    const back = await c.unwrapBytes(await c.kekFromPrf(prf), wrapped.wrapped_key, wrapped.iv);
    check("PRF output is deterministic as a KEK across derivations", c.b64(back) === c.b64(mk));

    // A different PRF value must not open it.
    const wrongKek = await c.kekFromPrf(crypto.getRandomValues(new Uint8Array(32)));
    let refused = false;
    try {
      await c.unwrapBytes(wrongKek, wrapped.wrapped_key, wrapped.iv);
    } catch {
      refused = true;
    }
    check("a different PRF value cannot unwrap the master key", refused);

    // Passphrase path, and that it is independent of the PRF path.
    const kdf = c.passphraseParams();
    const passKek = await c.kekFromPassphrase("correct horse battery", kdf.kdf_salt, 10000);
    const passWrapped = await c.wrapBytes(passKek, mk);
    const passBack = await c.unwrapBytes(
      await c.kekFromPassphrase("correct horse battery", kdf.kdf_salt, 10000),
      passWrapped.wrapped_key,
      passWrapped.iv,
    );
    check("the same master key unwraps from the passphrase path too", c.b64(passBack) === c.b64(mk));

    let wrongPass = false;
    try {
      await c.unwrapBytes(
        await c.kekFromPassphrase("wrong passphrase", kdf.kdf_salt, 10000),
        passWrapped.wrapped_key,
        passWrapped.iv,
      );
    } catch {
      wrongPass = true;
    }
    check("a wrong passphrase is refused", wrongPass);

    // The full sharing chain: MK -> group key -> content key -> field.
    const groupKey = c.generateGroupKey();
    const groupWrap = await c.wrapUnder(mk, groupKey);
    const contentKey = c.generateContentKey();
    const field = await c.encryptField(contentKey, "1987-03-02");
    const grant = await c.wrapUnder(groupKey, contentKey);

    // What a *reader* does: unseal the group key, unwrap the content key, read.
    const readerGroupKey = await c.unwrapUnder(mk, groupWrap.wrapped_key, groupWrap.iv);
    const readerContentKey = await c.unwrapUnder(
      readerGroupKey,
      grant.wrapped_key,
      grant.iv,
    );
    const value = await c.decryptField(readerContentKey, field.ciphertext, field.iv);
    check("MK -> group key -> content key -> field round-trips", value === "1987-03-02");

    // The property the whole app rests on: the stored bytes do not contain the value.
    const stored = [field.ciphertext, field.iv, grant.wrapped_key, groupWrap.wrapped_key].join(" ");
    check("no plaintext in anything the server stores", !stored.includes("1987"));

    // A reader outside the audience holds a different group key and gets nothing.
    let outsider = false;
    try {
      await c.unwrapUnder(c.generateGroupKey(), grant.wrapped_key, grant.iv);
    } catch {
      outsider = true;
    }
    check("a non-member's group key cannot unwrap the content key", outsider);
    break;
  }

  default:
    console.error(`unknown command: ${command}`);
    process.exit(2);
}

process.exit(failures === 0 ? 0 : 1);
