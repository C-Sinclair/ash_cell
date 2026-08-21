defmodule Vcs.Store.Refs do
  @moduledoc """
  Advancing a branch, as a compare-and-set.

  This is the part of the design that differs most from Git. A Git server takes
  `refs/heads/main.lock` on the filesystem, re-reads the ref, compares, writes, unlinks. The
  lock file *is* the concurrency control, and it lives outside the data.

  Here the ref lives in the repository's own SQLite file, which one process owns with a pool of
  exactly one connection, so the CAS is a single conditional statement against a serialised
  writer. There is no lock file, because there is nothing to lock against: the database is the
  serialisation point.

  Expressed as raw SQL rather than an Ash action because AshSqlite reports
  `can?(:transact) → false` — a read-then-write in Ash would have no transaction around it,
  and the whole point here is that the comparison and the write are one statement.
  """

  alias Ecto.Adapters.SQL

  @doc """
  Moves `name` from `expected` to `new`.

  `expected` is `nil` when the client believes the ref does not exist yet. Returns
  `{:error, {:stale, current}}` when the server has moved on, which is the honest answer to a
  race: the loser is told what it actually lost to.
  """
  def compare_and_set(repo_name, name, expected, new) do
    AshCell.with_tenant(repo_name, fn ->
      repo = Vcs.CellRepo.get_dynamic_repo()
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      result =
        case expected do
          nil ->
            # `WHERE NOT EXISTS` rather than `INSERT OR IGNORE`: a row that already exists must
            # be a *failure*, not a silent no-op, or a second pusher would think it won.
            SQL.query!(
              repo,
              """
              INSERT INTO refs (name, commit_id, updated_at)
              SELECT ?1, ?2, ?3
              WHERE NOT EXISTS (SELECT 1 FROM refs WHERE name = ?1)
              """,
              [name, new, now]
            )

          expected ->
            SQL.query!(
              repo,
              "UPDATE refs SET commit_id = ?1, updated_at = ?2 WHERE name = ?3 AND commit_id = ?4",
              [new, now, name, expected]
            )
        end

      if result.num_rows == 1 do
        {:ok, new}
      else
        {:error, {:stale, current(repo, name)}}
      end
    end)
  end

  @doc "Every ref in the repository, as a plain map."
  def all(repo_name) do
    Vcs.Store.Ref.read!(tenant: repo_name)
    |> Map.new(fn ref -> {ref.name, ref.commit_id} end)
  end

  defp current(repo, name) do
    case SQL.query!(repo, "SELECT commit_id FROM refs WHERE name = ?1", [name]) do
      %{rows: [[commit_id]]} -> commit_id
      _ -> nil
    end
  end
end
