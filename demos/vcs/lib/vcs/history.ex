defmodule Vcs.History do
  @moduledoc """
  History as queries, not walks.

  This module is the reason the whole exercise is interesting. Git answers "which commits
  touched `lib/foo.ex`" by decoding every commit and diffing trees; there is no index to
  consult because the object store is a content-addressed heap. A repository that *is* a
  database has an index, so the same question is one join.

  Every function here answers without the client cloning anything.
  """

  require Ash.Query

  @doc "Commits newest first, walking the projected parent chain."
  def log(repo_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case Keyword.get(opts, :from) || tip(repo_name) do
      nil -> []
      start -> chain(repo_name, start, limit, [])
    end
  end

  @doc """
  Commits that *changed* `path`, newest first.

  The distinction matters. One indexed read gets every commit whose snapshot contains the path
  — but with flat trees that is every commit since the file appeared, which is not what anyone
  means by a file's history. A commit changed the path when its blob for that path differs from
  its parent's, so the answer is that read plus a comparison along the parent chain.

  Still no object decoding, no tree diffing, and no clone. Git reaches the same answer by
  walking every commit and diffing trees; here the walk is over one indexed column.
  """
  def touching(repo_name, path) do
    blobs =
      Vcs.Store.CommitPath
      |> Ash.Query.filter(path == ^path)
      |> Ash.Query.select([:commit_id, :blob_id])
      |> Ash.read!(tenant: repo_name)
      |> Map.new(fn row -> {row.commit_id, row.blob_id} end)

    repo_name
    |> log(limit: 10_000)
    |> Enum.filter(fn commit ->
      mine = Map.get(blobs, commit.id)
      # A path absent from both sides was not touched; absent from one side is an add or a
      # delete, which counts.
      not is_nil(mine) and mine != Map.get(blobs, commit.parent_id)
    end)
  end

  @doc "Commits whose message contains `term`, case-insensitively."
  def search(repo_name, term) do
    needle = String.downcase(term)
    order = ordering(repo_name)

    Vcs.Store.Commit
    |> Ash.Query.filter(contains(fragment("lower(?)", message), ^needle))
    |> Ash.read!(tenant: repo_name)
    |> Enum.sort_by(&Map.get(order, &1.id, 0), :desc)
  end

  @doc "Every path in the repository's current tip, with the commit that last touched it."
  def paths(repo_name) do
    case tip(repo_name) do
      nil ->
        []

      tip ->
        Vcs.Store.CommitPath
        |> Ash.Query.filter(commit_id == ^tip)
        |> Ash.Query.sort(path: :asc)
        |> Ash.read!(tenant: repo_name)
    end
  end

  def tip(repo_name, ref \\ "refs/heads/main") do
    Map.get(Vcs.Store.Refs.all(repo_name), ref)
  end

  # Commit ids in topological order, so query results can be sorted the way a log reads.
  # AshSqlite has no aggregates and the parent chain is not expressible as one sort, so the
  # ordering comes from the walk we already know how to do.
  defp ordering(repo_name) do
    repo_name
    |> log(limit: 10_000)
    |> Enum.with_index()
    |> Map.new(fn {commit, index} -> {commit.id, -index} end)
  end

  defp chain(_repo_name, _id, 0, acc), do: Enum.reverse(acc)

  defp chain(repo_name, id, limit, acc) do
    case Vcs.Store.Commit |> Ash.Query.filter(id == ^id) |> Ash.read_one!(tenant: repo_name) do
      nil -> Enum.reverse(acc)
      commit when is_nil(commit.parent_id) -> Enum.reverse([commit | acc])
      commit -> chain(repo_name, commit.parent_id, limit - 1, [commit | acc])
    end
  end
end
