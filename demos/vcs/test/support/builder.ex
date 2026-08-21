defmodule Vcs.Test.Builder do
  @moduledoc """
  Builds wire objects the way the Rust client does.

  Deliberately a second implementation of the format rather than a call into the server's
  encoder: if both halves agreed only because they shared code, the format would not be
  proven interoperable at all.
  """

  def blob(contents) do
    encode("blob", contents)
  end

  def tree(entries) do
    payload =
      entries
      |> Enum.sort_by(& &1.path)
      |> Enum.map(fn entry ->
        %{"path" => entry.path, "blob" => entry.blob, "size" => entry.size}
      end)
      |> Jason.encode!()

    encode("tree", payload)
  end

  def commit(fields) do
    payload =
      Jason.encode!(%{
        "tree" => fields.tree,
        "parent" => Map.get(fields, :parent),
        "message" => fields.message,
        "timestamp" => Map.get(fields, :timestamp, "2026-08-20T12:00:00Z"),
        "author" => Map.get(fields, :author, "tester")
      })

    encode("commit", payload)
  end

  @doc """
  A one-file commit, returning `{commit_id, wire_objects}`.

  `wire_objects` are in the shape the HTTP API takes, so a test can push them without knowing
  anything about encoding.
  """
  def snapshot(path, contents, message, parent \\ nil) do
    blob = blob(contents)
    tree = tree([%{path: path, blob: blob.id, size: byte_size(contents)}])

    commit =
      commit(%{tree: tree.id, parent: parent, message: message})

    {commit.id, Enum.map([blob, tree, commit], &wire/1)}
  end

  def wire(object) do
    %{"id" => object.id, "kind" => object.kind, "encoded_b64" => Base.encode64(object.encoded)}
  end

  defp encode(kind, payload) do
    encoded = "#{kind} #{byte_size(payload)}" <> <<0>> <> payload

    %{
      id: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower),
      kind: kind,
      encoded: encoded
    }
  end
end
