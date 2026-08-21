// The bridge between LiveView and the key hierarchy.
//
// The pattern throughout: **the server renders ciphertext, the client decrypts in
// place.** LiveView diffs opaque base64 perfectly well and has no idea what it is
// pushing around, which is the point. Every hook here is idempotent, because a
// LiveView patch can re-run `updated()` at any time and decrypting twice must not
// produce garbage.
//
// Nothing in this file holds a key. Keys live in session.js; these hooks ask it to
// do things.

import * as c from "./crypto.js";
import * as s from "./session.js";
import * as wa from "./webauthn.js";

const parseJSON = (el, attr) => {
  const raw = el.getAttribute(attr);
  return raw ? JSON.parse(raw) : null;
};

// ---------------------------------------------------------------- Auth

export const Auth = {
  mounted() {
    // Listeners live on the container and dispatch by target, rather than being
    // attached to each button. LiveView replaces the buttons whenever the mode
    // switches, and per-button listeners would be replaced along with them --
    // leaving a form that silently does nothing on the second click. Delegation is
    // what lets this coexist with LiveView owning the DOM inside.
    this.el.addEventListener("click", (ev) => {
      const register = ev.target.closest("[data-register]");
      const login = ev.target.closest("[data-login]");
      if (register) this.run(ev, "register");
      else if (login) this.run(ev, "login");
    });
  },

  status(msg, kind = "info") {
    const el = this.el.querySelector("[data-status]");
    if (!el) return;
    el.textContent = msg;
    el.dataset.kind = kind;
  },

  busy(on) {
    this.el.querySelectorAll("button").forEach((b) => (b.disabled = on));
  },

  async run(ev, mode) {
    ev.preventDefault();
    const passphrase = this.el.querySelector("[name=passphrase]")?.value || "";

    if (mode === "register") {
      const handle = this.el.querySelector("[name=handle]")?.value.trim();
      if (!handle) return this.status("pick a handle first", "error");
      if (passphrase.length < 8) {
        return this.status("recovery passphrase must be at least 8 characters", "error");
      }
    }

    this.busy(true);
    this.status("waiting for your passkey\u2026");

    try {
      const result =
        mode === "register"
          ? await wa.register(this.el.querySelector("[name=handle]").value.trim(), passphrase)
          : await wa.login(passphrase);

      // Deliberately NOT unlocking the session here, and deliberately a full document
      // load. This hop cannot be a LiveView patch for two independent reasons: it
      // crosses a live_session boundary (which forces a reload regardless), and the
      // LiveView socket captured its session at connect time -- before /auth set the
      // cookie -- so an authenticated mount over this socket would see no user.
      //
      // A full load discards module state, so the key derived a moment ago is gone.
      // The alternative would be parking it in sessionStorage for one hop, which
      // weakens the one property the app is built on for the sake of one prompt. So:
      // the user authenticates here, and unlocks once on arrival.
      result.mk.fill(0);
      window.location = "/home";
    } catch (e) {
      this.status(e.message, "error");
      this.busy(false);
    }
  },
};

// ---------------------------------------------------------------- Unlock
//
// A page load loses the master key — by design; see session.js. So every
// authenticated page mounts this, and if the session is locked it asks for a
// passkey before any Tier 1 data can be rendered.

export const Unlock = {
  mounted() {
    this.bind();
    this.reconcile();
  },
  updated() {
    this.reconcile();
  },
  bind() {
    if (this.bound) return;
    this.bound = true;

    // Delegated, so a LiveView patch that replaces the panel does not silently
    // detach the only way to unlock.
    this.el.addEventListener("click", async (ev) => {
      if (!ev.target.closest("[data-unlock]")) return;
      ev.preventDefault();

      const passphrase = this.el.querySelector("[name=passphrase]")?.value || null;
      try {
        const { mk, identityPrivateKeyBytes } = await wa.login(passphrase);
        s.unlock(mk, identityPrivateKeyBytes);
        this.reconcile();

        // Emphatically not reload(). Reloading discards the key that was just
        // unwrapped, which made unlocking impossible: every successful unlock
        // immediately undid itself. Instead, tell the page a key is available and
        // let the decrypting hooks act on it in place.
        window.dispatchEvent(new CustomEvent("shroud:unlocked"));
        this.pushEvent("unlocked", {});
      } catch (e) {
        const st = this.el.querySelector("[data-status]");
        if (st) st.textContent = e.message;
      }
    });
  },

  reconcile() {
    this.el.dataset.locked = String(s.locked());
  },
};

// ---------------------------------------------------------------- OwnProfile

export const OwnProfile = {
  // A key can arrive *after* this hook mounts -- the page renders locked, then the
  // user unlocks. Without this listener the ciphertext would sit there decryptable
  // but never decrypted until the next patch happened to touch the container.
  listen() {
    if (this.listening) return;
    this.listening = true;
    this.onUnlocked = () => this.decryptAll();
    window.addEventListener("shroud:unlocked", this.onUnlocked);
  },

  destroyed() {
    if (this.onUnlocked) window.removeEventListener("shroud:unlocked", this.onUnlocked);
  },

  async mounted() {
    this.listen();
    await this.decryptAll();
    this.bindForm();
  },

  async updated() {
    await this.decryptAll();
  },

  // Each row carries its ciphertext and the owner's own wrapped content key. The
  // owner's wrap is easy to forget when writing — the symptom is a user locked out
  // of a field they just saved.
  async decryptAll() {
    if (s.locked()) return;
    for (const row of this.el.querySelectorAll("[data-field]")) {
      if (row.dataset.decrypted === "true") continue;
      const field = parseJSON(row, "data-field");
      const ownWrap = parseJSON(row, "data-own-wrap");
      const out = row.querySelector("[data-value]");
      if (!field || !ownWrap || !out) continue;
      try {
        out.value = await s.openOwnField(field, ownWrap);
        out.textContent = out.value;
        row.dataset.decrypted = "true";
      } catch (e) {
        out.value = "";
        out.placeholder = "could not decrypt with this key";
        row.dataset.decrypted = "error";
      }
    }
  },

  // Delegated for the same reason as Auth: LiveView replaces these rows on every
  // patch, so a listener attached to a save button dies with the button it was on.
  bindForm() {
    this.el.addEventListener("click", async (ev) => {
      const btn = ev.target.closest("[data-save]");
      if (!btn) return;
      ev.preventDefault();
      if (s.locked()) return;

      const row = btn.closest("[data-field-row]");
      const key = row.dataset.fieldKey;
      const value = row.querySelector("[data-value]").value;

      // Which audiences this field goes to, and the group key for each. The group
      // keys come from the owner's own cell, wrapped under MK.
      const audiences = [];
      for (const box of row.querySelectorAll("[data-audience]:checked")) {
        const slug = box.dataset.audience;
        const wrapped = parseJSON(box, "data-wrapped-group-key");
        audiences.push([slug, await s.groupKeyFor(slug, wrapped)]);
      }

      const sealed = await s.sealField(key, value, audiences);
      this.pushEvent("put_field", sealed);
    });
  },
};

// ---------------------------------------------------------------- Timeline
//
// Decrypts private posts in place. Public posts arrive already readable and are
// skipped entirely -- there is nothing to do, which is the honest consequence of
// public meaning public.

export const Timeline = {
  listen() {
    if (this.listening) return;
    this.listening = true;
    this.onUnlocked = () => this.decryptAll();
    window.addEventListener("shroud:unlocked", this.onUnlocked);
  },

  destroyed() {
    if (this.onUnlocked) window.removeEventListener("shroud:unlocked", this.onUnlocked);
  },

  async mounted() {
    this.listen();
    await this.decryptAll();
  },

  async updated() {
    await this.decryptAll();
  },

  async decryptAll() {
    const identity = s.identity();

    for (const card of this.el.querySelectorAll("[data-post]")) {
      const slot = card.querySelector("[data-body]");
      if (!slot || slot.dataset.state === "clear") continue;

      if (s.locked()) {
        slot.dataset.state = "locked";
        slot.textContent = "encrypted \u2014 unlock to read";
        continue;
      }

      const post = parseJSON(card, "data-post");
      if (!post) continue;

      try {
        slot.textContent = await s.openPost(post, identity);
        slot.dataset.state = "clear";
      } catch (_) {
        // The honest rendering when the key is gone rather than merely absent: a
        // shredded author's ciphertext is still here and never will open again.
        slot.textContent = "unreadable \u2014 key destroyed";
        slot.dataset.state = "shredded";
      }
    }
  },
};

// ---------------------------------------------------------------- Composer

export const Composer = {
  mounted() {
    this.hint();

    this.el.addEventListener("change", (ev) => {
      if (ev.target.closest("[data-visibility]")) this.hint();
    });

    this.el.addEventListener("click", async (ev) => {
      if (!ev.target.closest("[data-publish]")) return;
      ev.preventDefault();
      await this.publish();
    });

    // Cmd/Ctrl+Enter to post, because a composer that only has a button feels broken.
    this.el.addEventListener("keydown", async (ev) => {
      if (ev.key === "Enter" && (ev.metaKey || ev.ctrlKey)) {
        ev.preventDefault();
        await this.publish();
      }
    });

    // The audiences a post can go to, with their wrapped group keys, pushed by the
    // LiveView. Kept out of the DOM: it is not rendered anywhere, so an attribute
    // would be carrying key material around for no reason.
    this.handleEvent("audiences", ({ audiences }) => {
      this.audiences = audiences;
    });
  },

  status(msg) {
    this.el.querySelector("[data-status]").textContent = msg || "";
  },

  // Says what will actually happen, before it happens. The difference between these
  // two outcomes is the entire app, so it should not be something a user has to infer
  // from a padlock glyph.
  hint() {
    const visibility = this.el.querySelector("[data-visibility]").value;
    const hint = this.el.querySelector("[data-hint]");
    hint.textContent =
      visibility === "public"
        ? "stored in the clear \u2014 the server can read this"
        : "encrypted in this tab \u2014 the server stores ciphertext";
  },

  async publish() {
    const bodyEl = this.el.querySelector("[data-body]");
    const body = bodyEl.value.trim();
    const visibility = this.el.querySelector("[data-visibility]").value;

    if (!body) return;
    this.status("");

    if (visibility === "public") {
      // No key needed, and none used. A public post is plaintext by definition.
      this.pushEvent("publish", { visibility: "public", body });
      bodyEl.value = "";
      return;
    }

    if (s.locked()) return this.status("unlock first \u2014 a private post needs your key");

    const audience = (this.audiences || []).find((a) => a.slug === visibility);
    if (!audience) return this.status("unknown audience");

    try {
      const groupKey = await s.groupKeyFor(audience.slug, audience);
      const sealed = await s.sealPost(body, audience.slug, groupKey);
      this.pushEvent("publish", sealed);
      bodyEl.value = "";
    } catch (e) {
      this.status(e.message);
    }
  },
};

// ---------------------------------------------------------------- KeyPanel

export const KeyPanel = {
  mounted() {
    this.render();
    this.onUnlocked = () => this.render();
    window.addEventListener("shroud:unlocked", this.onUnlocked);
  },
  updated() {
    this.render();
  },
  destroyed() {
    window.removeEventListener("shroud:unlocked", this.onUnlocked);
  },
  render() {
    const el = this.el.querySelector("[data-key-state]");
    if (!el) return;
    el.textContent = s.locked()
      ? "Locked \u2014 encrypted posts stay unreadable."
      : "Unlocked in this tab.";
    el.className = s.locked()
      ? "mt-1 text-[13px] font-medium text-amber-700"
      : "mt-1 text-[13px] font-medium text-emerald-700";
  },
};

// ---------------------------------------------------------------- Audiences

export const Audiences = {
  mounted() {
    this.el.addEventListener("click", async (ev) => {
      if (!ev.target.closest("[data-new-audience]")) return;
      ev.preventDefault();
      if (s.locked()) return;
      const input = this.el.querySelector("[name=audience_name]");
      const name = input.value.trim();
      if (!name) return;
      const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-");
      const { wrapped_group_key, iv } = await s.newGroupKey(slug);
      input.value = "";
      this.pushEvent("put_audience", { slug, name, wrapped_group_key, iv });
    });

    // Adding a member means seal this audience's group key to their published
    // public key. One wrap per member, once — not per field, and not per read.
    this.handleEvent("seal_group_key_for", async ({ slug, member_id, public_key, wrapped }) => {
      if (s.locked()) return;
      const groupKey = await s.groupKeyFor(slug, wrapped);
      const sealed = await c.sealTo(public_key, groupKey);
      this.pushEvent("member_sealed", { slug, member_id, sealed });
    });
  },
};

export default { Auth, Unlock, OwnProfile, Timeline, Composer, KeyPanel, Audiences };
