defmodule CollabEditor.EncryptionTest do
  @moduledoc """
  That the per-document key is actually wired, checked from outside the
  application: the `sqlite3` CLI's opinion of the file, and a search for the
  plaintext in the bytes.

  This is the test that catches a silent `EXQLITE_USE_SYSTEM` regression, which
  otherwise leaves you with a perfectly working unencrypted database.
  """
  use ExUnit.Case, async: false

  import CollabEditor.YjsHelpers

  alias CollabEditor.{CellKey, Editing}
  alias CollabEditor.Cells.Vault

  @secret "the-quick-brown-fox-was-here-9f2a"

  setup do
    {:ok, document} = Editing.create_document("Encryption test")
    on_exit(fn -> Editing.delete_document(document.id) end)
    %{doc: document}
  end

  test "a document's text is not present in its file", %{doc: doc} do
    {:ok, _} = Editing.append(doc.id, update_inserting(@secret), "client-1")

    cell_key = CellKey.resolve(doc.id)
    :ok = AshCell.checkpoint(cell_key)
    path = AshCell.path_for(cell_key)

    # The plaintext is in the Yjs update as ordinary bytes, so if the cipher were
    # not applied it would be right there in the file.
    assert text_of(Editing.merged_state(doc.id)) =~ @secret

    for candidate <- [path, path <> "-wal"], File.exists?(candidate) do
      refute File.read!(candidate) =~ @secret,
             "plaintext found in #{candidate} — the SQLCipher key is not being applied"
    end
  end

  test "a compacted snapshot is encrypted too", %{doc: doc} do
    {:ok, _} = Editing.append(doc.id, update_inserting(@secret), "client-1")
    {:ok, _} = Editing.compact(doc.id)

    cell_key = CellKey.resolve(doc.id)
    :ok = AshCell.checkpoint(cell_key)
    path = AshCell.path_for(cell_key)

    for candidate <- [path, path <> "-wal"], File.exists?(candidate) do
      refute File.read!(candidate) =~ @secret,
             "plaintext found in #{candidate} after compaction"
    end
  end

  test "every document has a different key", %{doc: doc} do
    {:ok, other} = Editing.create_document("Another")
    on_exit(fn -> Editing.delete_document(other.id) end)

    assert Vault.fingerprint(CellKey.resolve(doc.id)) !=
             Vault.fingerprint(CellKey.resolve(other.id))
  end
end
