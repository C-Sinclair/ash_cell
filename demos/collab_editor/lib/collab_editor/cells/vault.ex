defmodule CollabEditor.Cells.Vault do
  @moduledoc """
  Per-document encryption keys.

  Same shape as the console demo's vault, one level finer: the key is derived per
  *document*, so deleting a document's key crypto-shreds that document and nothing
  else. Keys are derived (HKDF over a root secret and the cell key) rather than
  minted, because a randomly generated in-memory key means every existing cell is
  unopenable after a restart.

  Not confidential computing: the node holds the plaintext key in order to serve
  the document.
  """

  @doc "The SQLCipher key literal for a cell, or `nil` if the document is shredded."
  def key_for(cell_key) do
    if shredded?(cell_key), do: nil, else: derive(cell_key)
  end

  @doc "Short, stable fingerprint for display. Never reveals the key."
  def fingerprint(cell_key) do
    case key_for(cell_key) do
      nil ->
        nil

      key ->
        :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    end
  end

  @doc """
  Destroys a document's key. The bytes stay on disk and are permanently
  meaningless; every other document keeps serving.
  """
  def shred(cell_key) do
    AshCell.close(cell_key)
    File.mkdir_p!(Path.dirname(shred_list()))
    File.write!(shred_list(), cell_key <> "\n", [:append])
    :ok
  end

  def shredded?(cell_key) do
    case File.read(shred_list()) do
      {:ok, contents} -> cell_key in String.split(contents, "\n", trim: true)
      _ -> false
    end
  end

  # exqlite interpolates this straight into `PRAGMA key = <value>`, so it has to
  # arrive as a valid SQL literal. `"x'<hex>'"` is SQLCipher's raw-key form.
  defp derive(cell_key) do
    key =
      :crypto.mac(:hmac, :sha256, root_secret(), "ashcell-collab:" <> cell_key)
      |> Base.encode16(case: :lower)

    ~s|"x'| <> key <> ~s|'"|
  end

  defp root_secret do
    Application.get_env(:collab_editor, :vault_root_secret) ||
      "collab-editor-root-secret-not-for-production"
  end

  defp shred_list do
    Path.join(Application.get_env(:collab_editor, :cell_dir, "priv/cells"), ".shredded")
  end
end
