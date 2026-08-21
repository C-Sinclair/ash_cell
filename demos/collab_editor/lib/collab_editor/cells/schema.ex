defmodule CollabEditor.Cells.Schema do
  @moduledoc """
  Versioned schema for one document's cell, applied on activation before the cell
  serves an edit.

  Three tables, and the split between them is the design:

    * `document` — one row, the document's own metadata. It lives in the document's
      cell rather than in a shared registry, so this demo needs no global database
      at all. The cost of that shows up in `CollabEditor.Editing.list_documents/0`.
    * `updates` — the append-only Yjs update log. Every keystroke anyone makes
      arrives here as a CRDT update, and `seq` is a monotonic integer assigned by
      the cell. The order is not what makes the *document* correct — CRDT updates
      commute — but it is what makes an incremental resume cheap: "everything after
      41" is answerable without exchanging state vectors.
    * `snapshots` — one row, the merged state of everything up to `through_seq`.
      This is what compaction produces, and the reason the log does not grow
      forever.

  ## The bit that needs a single writer

  Compaction is `read the whole log; merge; write the snapshot; delete what was
  merged`. That is a read-modify-write over the log, and it is exactly the
  operation a CRDT does *not* make safe: two nodes compacting concurrently can
  each merge a log that the other is truncating, and an update that arrives
  between one node's read and its delete is gone. A cell is a single serialising
  writer per document, so the whole sequence is one transaction on one connection
  with no coordination — see `CollabEditor.Editing.compact/1`.
  """
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE document (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    created_at TEXT NOT NULL
  )
  """)

  migration(2, """
  CREATE TABLE updates (
    seq INTEGER PRIMARY KEY,
    payload BLOB NOT NULL,
    client_id TEXT,
    at TEXT NOT NULL
  )
  """)

  migration(3, """
  CREATE TABLE snapshots (
    id TEXT PRIMARY KEY,
    state BLOB NOT NULL,
    through_seq INTEGER NOT NULL,
    updated_at TEXT NOT NULL
  )
  """)
end
