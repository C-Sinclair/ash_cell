defmodule Vcs.Objects do
  @moduledoc """
  The object format, server side.

  An object's bytes are `<kind> <payload-len>\\0<payload>` and its id is the SHA-256 of that
  whole string. The server recomputes the id from the bytes rather than trusting the one the
  client sent — content addressing is only a guarantee if somebody checks.
  """

  @kinds ~w(blob tree commit)

  @doc "The id of some encoded bytes."
  def id(encoded), do: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)

  @doc """
  Splits encoded bytes into `{kind, payload}`, verifying the declared length.

  A wrong length is the cheapest possible corruption check and it costs nothing, so it is
  always on.
  """
  def decode(encoded) when is_binary(encoded) do
    with [header, payload] <- :binary.split(encoded, <<0>>),
         [kind, declared] <- String.split(header, " ", parts: 2),
         true <- kind in @kinds,
         {size, ""} <- Integer.parse(declared),
         ^size <- byte_size(payload) do
      {:ok, kind, payload}
    else
      _ -> {:error, :malformed_object}
    end
  end

  @doc "The tree payload: a list of `%{path, blob, size}`, already sorted by the client."
  def decode_tree(payload) do
    case Jason.decode(payload) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      _ -> {:error, :malformed_tree}
    end
  end

  def decode_commit(payload) do
    case Jason.decode(payload) do
      {:ok, %{"tree" => _, "message" => _, "timestamp" => _} = commit} -> {:ok, commit}
      _ -> {:error, :malformed_commit}
    end
  end
end
