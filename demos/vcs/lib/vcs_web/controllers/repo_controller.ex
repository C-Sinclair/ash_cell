defmodule VcsWeb.RepoController do
  @moduledoc """
  One controller, one repository per request.

  The tenant is `owner/name` from the path, and nothing is inherited: every action passes it
  explicitly, because an AshCell binding lives in the process dictionary and a request process
  is not the process that started the cell.

  No authentication. That is a stated non-goal, and pretending otherwise would be worse than
  saying so.
  """
  use Phoenix.Controller, formats: [:json]

  # Reads must not bring a repository into existence — see `Vcs.Repos`. The push path is
  # exempt, all three steps of it, because creating the cell is precisely what a first push
  # does and `missing` is the step that runs before the repository exists.
  plug(:require_repo when action not in [:missing, :objects, :push])

  def refs(conn, params) do
    repo = repo_name(params)

    json(conn, %{repo: repo, refs: Vcs.Store.Refs.all(repo)})
  end

  def missing(conn, %{"ids" => ids} = params) when is_list(ids) do
    json(conn, %{missing: Vcs.Push.missing(repo_name(params), ids)})
  end

  def missing(conn, _params), do: bad_request(conn, "expected an `ids` array")

  def objects(conn, %{"objects" => objects} = params) when is_list(objects) do
    case Vcs.Push.store(repo_name(params), objects) do
      {:ok, stored} -> json(conn, %{stored: stored})
      {:error, reason} -> bad_request(conn, describe(reason))
    end
  end

  def objects(conn, _params), do: bad_request(conn, "expected an `objects` array")

  def push(conn, %{"ref" => reference, "new" => new} = params) do
    repo = repo_name(params)
    expected = Map.get(params, "expected")

    case Vcs.Push.advance(repo, reference, expected, new) do
      {:ok, commit} ->
        json(conn, %{ref: reference, commit: commit})

      {:error, {:stale, current}} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error:
            "rejected: #{reference} is #{short(current)} on the server, not #{short(expected)}. " <>
              "Another push won the race. Fetch first.",
          current: current
        })

      {:error, {:non_fast_forward, tip}} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "rejected: #{short(tip)} is not an ancestor of #{short(new)}",
          current: tip
        })

      {:error, {:unknown_commit, id}} ->
        bad_request(conn, "unknown commit #{short(id)}; send its objects first")
    end
  end

  def push(conn, _params), do: bad_request(conn, "expected `ref` and `new`")

  def fetch(conn, %{"want" => want} = params) when is_list(want) do
    have = Map.get(params, "have", [])

    json(conn, %{objects: Vcs.Push.closure(repo_name(params), want, have)})
  end

  def fetch(conn, _params), do: bad_request(conn, "expected a `want` array")

  def log(conn, params) do
    repo = repo_name(params)
    limit = integer_param(params, "limit", 50)

    json(conn, %{commits: Enum.map(Vcs.History.log(repo, limit: limit), &render_commit/1)})
  end

  def history(conn, %{"path" => path} = params) do
    repo = repo_name(params)

    json(conn, %{
      path: path,
      commits: Enum.map(Vcs.History.touching(repo, path), &render_commit/1)
    })
  end

  def history(conn, _params), do: bad_request(conn, "expected a `path` query parameter")

  def search(conn, %{"q" => term} = params) do
    repo = repo_name(params)

    json(conn, %{
      query: term,
      commits: Enum.map(Vcs.History.search(repo, term), &render_commit/1)
    })
  end

  def search(conn, _params), do: bad_request(conn, "expected a `q` query parameter")

  def tree(conn, params) do
    repo = repo_name(params)

    entries =
      Enum.map(Vcs.History.paths(repo), fn entry ->
        %{path: entry.path, blob: entry.blob_id, size: entry.size}
      end)

    json(conn, %{tip: Vcs.History.tip(repo), entries: entries})
  end

  defp require_repo(conn, _opts) do
    repo = repo_name(conn.params)

    if Vcs.Repos.exists?(repo) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "no such repository: #{repo}"})
      |> halt()
    end
  end

  defp repo_name(%{"owner" => owner, "name" => name}), do: "#{owner}/#{name}"

  defp render_commit(commit) do
    %{
      id: commit.id,
      parent: commit.parent_id,
      tree: commit.tree_id,
      message: commit.message,
      author: commit.author,
      timestamp: commit.committed_at
    }
  end

  defp integer_param(params, key, default) do
    case Integer.parse(Map.get(params, key, "")) do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: message})
  end

  defp short(nil), do: "(nothing)"
  defp short(id), do: String.slice(id, 0, 12)

  defp describe({:id_mismatch, id}),
    do: "object #{short(id)} does not hash to the id it claims"

  defp describe({:bad_base64, id}), do: "object #{short(id)} is not valid base64"
  defp describe({:malformed_object, id}), do: "object #{short(id)} is malformed"
  defp describe(other), do: "rejected: #{inspect(other)}"
end
