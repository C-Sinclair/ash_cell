// The browser half of the editor.
//
// Yjs does the merging: a keystroke produces a CRDT update, which goes to the
// server to be stored in the document's cell and relayed to everyone else. Two
// people typing in the same word converge character by character, and no
// keystroke is lost — that part is Yjs's guarantee, not the cell's.
//
// What goes over the wire is therefore just two kinds of bytes: updates, which are
// persisted, and awareness (cursors, names), which is relayed and never stored.
import {createEditor, $getRoot, $getSelection, $isRangeSelection, $createParagraphNode, FORMAT_TEXT_COMMAND} from "lexical"
import {registerRichText, HeadingNode, QuoteNode, $createHeadingNode, $createQuoteNode} from "@lexical/rich-text"
import {registerDragonSupport} from "@lexical/dragon"
import {mergeRegister} from "@lexical/utils"
import {$setBlocksType} from "@lexical/selection"
import {
  createBinding,
  createUndoManager,
  initLocalState,
  setLocalStateFocus,
  syncCursorPositions,
  syncLexicalUpdateToYjs,
  syncYjsChangesToLexical
} from "@lexical/yjs"
import * as Y from "yjs"
import {Awareness, applyAwarenessUpdate, encodeAwarenessUpdate} from "y-protocols/awareness"

const COLOURS = ["#f97316", "#22d3ee", "#a3e635", "#e879f9", "#facc15", "#60a5fa"]
const b64 = {
  encode: (bytes) => btoa(String.fromCharCode(...bytes)),
  decode: (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0))
}

// `@lexical/yjs` expects a y-websocket-shaped provider. It only ever uses
// `awareness` and the event registration, so this is the whole of it: the
// transport underneath is the LiveView channel.
function createProvider(doc, awareness) {
  const listeners = new Map()

  const emit = (type, payload) => (listeners.get(type) || []).forEach((cb) => cb(payload))

  return {
    awareness,
    connect: () => emit("status", {status: "connected"}),
    disconnect: () => emit("status", {status: "disconnected"}),
    on: (type, cb) => listeners.set(type, [...(listeners.get(type) || []), cb]),
    off: (type, cb) => listeners.set(type, (listeners.get(type) || []).filter((fn) => fn !== cb)),
    emit
  }
}

export default {
  mounted() {
    this.clientId = this.el.dataset.clientId
    this.seq = parseInt(this.el.dataset.head || "0", 10)
    this.name = "guest-" + this.clientId.slice(0, 4)
    this.colour = COLOURS[parseInt(this.clientId.slice(0, 2), 16) % COLOURS.length]

    this.doc = new Y.Doc()
    this.docMap = new Map([[this.clientId, this.doc]])
    this.awareness = new Awareness(this.doc)
    this.provider = createProvider(this.doc, this.awareness)

    this.editor = createEditor({
      namespace: "ashcell-collab",
      nodes: [HeadingNode, QuoteNode],
      onError: (error) => { throw error }
    })
    this.editor.setRootElement(this.el)

    this.binding = createBinding(this.editor, this.provider, "root", this.doc, this.docMap)
    this.undoManager = createUndoManager(this.binding, this.binding.root.getSharedType())

    const onYjsTreeChanges = (events, transaction) => {
      if (transaction.origin !== this.binding) {
        syncYjsChangesToLexical(this.binding, this.provider, events, transaction.origin === this.undoManager)
      }
    }

    this.binding.root.getSharedType().observeDeep(onYjsTreeChanges)

    // The local document changed. Everything that leaves this browser leaves from
    // here — an opaque Yjs update, with no idea what a paragraph is.
    const onDocUpdate = (update, origin) => {
      if (origin === "remote") return
      this.pushEvent("update", {update: b64.encode(update)})
    }

    this.doc.on("update", onDocUpdate)

    this.awareness.on("update", ({added, updated, removed}) => {
      syncCursorPositions(this.binding, this.provider)

      const changed = added.concat(updated, removed)
      if (changed.length === 0) return
      if (!changed.includes(this.doc.clientID)) return

      this.pushEvent("awareness", {
        update: b64.encode(encodeAwarenessUpdate(this.awareness, [this.doc.clientID]))
      })
    })

    this.teardown = mergeRegister(
      registerRichText(this.editor),
      registerDragonSupport(this.editor),
      this.editor.registerUpdateListener(({prevEditorState, editorState, dirtyElements, dirtyLeaves, normalizedNodes, tags}) => {
        syncLexicalUpdateToYjs(
          this.binding, this.provider, prevEditorState, editorState,
          dirtyElements, dirtyLeaves, normalizedNodes, tags
        )
      }),
      () => {
        this.binding.root.getSharedType().unobserveDeep(onYjsTreeChanges)
        this.doc.off("update", onDocUpdate)
      }
    )

    // Other people's carets are drawn into a sibling element rather than into the
    // editor, whose DOM Lexical owns. It has to be in the template with
    // `phx-update="ignore"`: an element created here is one LiveView does not know
    // about, and the next patch removes it — which loses the carets silently while
    // awareness keeps flowing.
    this.binding.cursorsContainer = document.getElementById("cursors")

    initLocalState(this.provider, this.name, this.colour, document.activeElement === this.el, {})
    this.trackFocus()

    this.applyRemote(b64.decode(this.el.dataset.state || ""))
    this.bootstrapIfEmpty()
    this.bindToolbar()

    this.handleEvent("remote_update", ({seq, update}) => {
      this.seq = Math.max(this.seq, seq)
      this.applyRemote(b64.decode(update))
    })

    this.handleEvent("remote_awareness", ({update}) => {
      applyAwarenessUpdate(this.awareness, b64.decode(update), "remote")
    })

    this.handleEvent("replay", ({updates}) => {
      updates.forEach(({seq, update}) => {
        this.seq = Math.max(this.seq, seq)
        this.applyRemote(b64.decode(update))
      })
    })

    // Compaction absorbed everything we missed, so there is no tail to replay.
    // Applying the whole snapshot is safe rather than merely convenient: a Yjs
    // update carries its own history, so re-applying state we already have is a
    // no-op instead of a duplication.
    this.handleEvent("reload", ({state, head}) => {
      this.seq = head
      this.applyRemote(b64.decode(state))
    })

    this.provider.connect()

    // A handle for poking at the CRDT from the browser console, which is half the
    // point of a demo: `__collab.doc`, `__collab.awareness.getStates()`.
    window.__collab = this
  },

  // The websocket dropped and came back. `phx-update="ignore"` means the editor and
  // its Y.Doc survived, so only the updates missed while it was down are needed —
  // which is what the cell's monotonic `seq` is for, even though the CRDT does not
  // need an order to converge.
  reconnected() {
    this.pushEvent("resume", {since: this.seq})
  },

  destroyed() {
    this.awareness.setLocalState(null)
    if (this.teardown) this.teardown()
  },

  applyRemote(update) {
    if (update.length === 0) return
    Y.applyUpdate(this.doc, update, "remote")
  },

  // A brand new document has no Yjs state at all, and Lexical needs at least one
  // paragraph to put a caret in. Only the client that finds it empty writes one;
  // if two do, the CRDT merges them and the document opens with two empty
  // paragraphs rather than a conflict.
  bootstrapIfEmpty() {
    if (this.binding.root.isEmpty() && this.binding.root._xmlText._length === 0) {
      this.editor.update(() => {
        const root = $getRoot()
        if (root.getChildrenSize() === 0) root.append($createParagraphNode())
      }, {tag: "history-merge"})
    }
  },

  trackFocus() {
    this.el.addEventListener("focus", () =>
      setLocalStateFocus(this.provider, this.name, this.colour, true, {})
    )
    this.el.addEventListener("blur", () =>
      setLocalStateFocus(this.provider, this.name, this.colour, false, {})
    )
  },

  bindToolbar() {
    document.querySelectorAll(".editor-tool").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.preventDefault()
        this.editor.dispatchCommand(FORMAT_TEXT_COMMAND, button.dataset.format)
      })
    })

    document.querySelectorAll(".editor-block").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.preventDefault()

        this.editor.update(() => {
          const selection = $getSelection()
          if (!$isRangeSelection(selection)) return

          const factory = {
            h1: () => $createHeadingNode("h1"),
            h2: () => $createHeadingNode("h2"),
            quote: () => $createQuoteNode(),
            paragraph: () => $createParagraphNode()
          }[button.dataset.block]

          if (factory) $setBlocksType(selection, factory)
        })
      })
    })
  }
}
