defmodule Vcs.Push do
  @moduledoc """
  The server half of push and fetch.

  Objects first, then the ref. Objects are content-addressed and idempotent, so sending them
  twice is free and a crash between the two steps leaves unreferenced objects rather than a
  broken repository. That ordering is not a workaround for AshSqlite's lack of transactions —
  Git makes the same choice for the same reason, because no forge can make "upload objects" and
  "move the ref" a single atomic act across a network.

  What *is* atomic is the ref move itself. See `Vcs.Store.Refs`.
  """

  require Ash.Query

  @chunk 400

  @doc "Which of `ids` this repository does not have yet."
  def missing(repo_name, ids) do
    known = known_ids(repo_name, ids)

    Enum.reject(ids, &MapSet.member?(known, &1))
  end

  @doc """
  Stores objects, verifying each id against its bytes.

  Commits and trees are also projected into `commits` and `commit_paths`, which is what makes
  history queryable later. Blobs and trees are stored before commits so a commit's tree is
  always resolvable by the time it is projected.
  """
  def store(repo_name, wire_objects) do
    with {:ok, decoded} <- decode_all(wire_objects) do
      {commits, others} = Enum.split_with(decoded, &(&1.kind == "commit"))
      ordered = others ++ commits

      Enum.each(ordered, fn object ->
        insert_object(repo_name, object)

        if object.kind == "commit", do: project_commit(repo_name, object)
      end)

      {:ok, length(ordered)}
    end
  end

  @doc """
  Moves a ref, fast-forward only.

  The client checks this too, for a good local error. The server checks it because the server
  is the authority: a client that skipped the check, or raced another push, must still be
  refused.
  """
  def advance(repo_name, name, expected, new) do
    cond do
      not object?(repo_name, new) ->
        {:error, {:unknown_commit, new}}

      not is_nil(expected) and not ancestor?(repo_name, expected, new) ->
        {:error, {:non_fast_forward, expected}}

      true ->
        Vcs.Store.Refs.compare_and_set(repo_name, name, expected, new)
    end
  end

  @doc "The transitive closure of `want`, minus everything in `have`."
  def closure(repo_name, want, have) do
    have = MapSet.new(have)

    want
    |> Enum.reduce(MapSet.new(), fn tip, acc -> walk_closure(repo_name, tip, acc) end)
    |> Enum.reject(&MapSet.member?(have, &1))
    |> then(&fetch_objects(repo_name, &1))
  end

  # ---- internals -----------------------------------------------------------------

  defp decode_all(wire_objects) do
    Enum.reduce_while(wire_objects, {:ok, []}, fn object, {:ok, acc} ->
      case decode_one(object) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_one(%{"id" => claimed, "encoded_b64" => body_b64}) do
    with {:ok, encoded} <- Base.decode64(body_b64),
         actual = Vcs.Objects.id(encoded),
         # The client's id is a claim; the bytes are the fact.
         true <- actual == claimed,
         {:ok, kind, payload} <- Vcs.Objects.decode(encoded) do
      {:ok, %{id: actual, kind: kind, payload: payload, encoded: encoded}}
    else
      false -> {:error, {:id_mismatch, claimed}}
      :error -> {:error, {:bad_base64, claimed}}
      {:error, reason} -> {:error, {reason, claimed}}
    end
  end

  defp decode_one(_), do: {:error, :malformed_request}

  defp insert_object(repo_name, object) do
    Vcs.Store.Object.create(
      %{
        id: object.id,
        kind: object.kind,
        size: byte_size(object.payload),
        body: object.encoded
      },
      tenant: repo_name
    )
    |> case do
      {:ok, _} -> :ok
      # An object that is already present cannot differ from what we would have written, so a
      # collision on the primary key means the work is done.
      {:error, _} -> :ok
    end
  end

  defp project_commit(repo_name, object) do
    with {:ok, commit} <- Vcs.Objects.decode_commit(object.payload),
         {:ok, entries} <- tree_entries(repo_name, commit["tree"]) do
      Vcs.Store.Commit.create(
        %{
          id: object.id,
          parent_id: commit["parent"],
          tree_id: commit["tree"],
          message: commit["message"],
          author: commit["author"],
          committed_at: commit["timestamp"]
        },
        tenant: repo_name
      )

      Enum.each(entries, fn entry ->
        Vcs.Store.CommitPath.create(
          %{
            commit_id: object.id,
            path: entry["path"],
            blob_id: entry["blob"],
            size: entry["size"] || 0
          },
          tenant: repo_name
        )
      end)

      :ok
    else
      _ -> :ok
    end
  end

  defp tree_entries(repo_name, tree_id) do
    with %{body: body} <- read_object(repo_name, tree_id),
         {:ok, "tree", payload} <- Vcs.Objects.decode(body) do
      Vcs.Objects.decode_tree(payload)
    else
      _ -> {:error, :missing_tree}
    end
  end

  defp read_object(repo_name, id) do
    Vcs.Store.Object
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(tenant: repo_name)
  end

  defp object?(repo_name, id), do: not is_nil(read_object(repo_name, id))

  defp known_ids(repo_name, ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(MapSet.new(), fn chunk, acc ->
      Vcs.Store.Object
      |> Ash.Query.filter(id in ^chunk)
      |> Ash.Query.select([:id])
      |> Ash.read!(tenant: repo_name)
      |> Enum.reduce(acc, fn object, acc -> MapSet.put(acc, object.id) end)
    end)
  end

  # Walks the commit chain, collecting the commit, its tree, and every blob the tree names.
  defp walk_closure(repo_name, commit_id, acc) do
    if MapSet.member?(acc, commit_id) do
      acc
    else
      case commit_row(repo_name, commit_id) do
        nil ->
          acc

        commit ->
          blobs =
            repo_name
            |> paths_of(commit.id)
            |> Enum.map(& &1.blob_id)

          acc =
            acc
            |> MapSet.put(commit.id)
            |> MapSet.put(commit.tree_id)
            |> MapSet.union(MapSet.new(blobs))

          case commit.parent_id do
            nil -> acc
            parent -> walk_closure(repo_name, parent, acc)
          end
      end
    end
  end

  defp ancestor?(repo_name, candidate, from) do
    cond do
      candidate == from ->
        true

      true ->
        case commit_row(repo_name, from) do
          nil -> false
          %{parent_id: nil} -> false
          %{parent_id: parent} -> ancestor?(repo_name, candidate, parent)
        end
    end
  end

  defp commit_row(repo_name, id) do
    Vcs.Store.Commit
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(tenant: repo_name)
  end

  defp paths_of(repo_name, commit_id) do
    Vcs.Store.CommitPath
    |> Ash.Query.filter(commit_id == ^commit_id)
    |> Ash.read!(tenant: repo_name)
  end

  defp fetch_objects(repo_name, ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Vcs.Store.Object
      |> Ash.Query.filter(id in ^chunk)
      |> Ash.read!(tenant: repo_name)
    end)
    |> Enum.map(fn object ->
      %{id: object.id, kind: object.kind, encoded_b64: Base.encode64(object.body)}
    end)
  end
end
