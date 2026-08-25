defmodule Branch.Catalog do
  @moduledoc """
  What databases and branches exist, and where each branch came from.

  Provenance lives here rather than inside a cell, and that is load-bearing rather
  than convenient: a branch is a *copy of its origin's file*, so a provenance row
  written inside the origin would be copied into the branch, and the branch would
  then carry a record claiming to be its own parent. The record has to live outside
  both.

  It also holds the one number merge depends on — the content digest of the snapshot
  the branch was cut from ([ADR-23](../../../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md)).
  Nothing in either cell remembers it, so if this table is lost, open branches become
  unmergeable. They are not unreadable: a branch is a database in its own right and
  keeps working. Only the promotion path needs the catalog.
  """

  import Ecto.Query

  alias Branch.CatalogRepo

  defmodule Database do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:name, :string, []}
    schema "databases" do
      field(:created_at, :utc_datetime)
    end
  end

  defmodule BranchRow do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :string, []}
    schema "branches" do
      field(:database, :string)
      field(:name, :string)
      # nil for a root branch: it was provisioned, not cut from anything.
      field(:parent, :string)
      field(:from_txid, :integer)
      field(:digest, :string)
      field(:status, :string, default: "open")
      field(:created_at, :utc_datetime)
      field(:merged_at, :utc_datetime)
    end
  end

  def migrate do
    Ecto.Adapters.SQL.query!(
      CatalogRepo,
      "CREATE TABLE IF NOT EXISTS databases (name TEXT PRIMARY KEY, created_at TEXT NOT NULL)",
      []
    )

    Ecto.Adapters.SQL.query!(
      CatalogRepo,
      """
      CREATE TABLE IF NOT EXISTS branches (
        id TEXT PRIMARY KEY,
        database TEXT NOT NULL,
        name TEXT NOT NULL,
        parent TEXT,
        from_txid INTEGER,
        digest TEXT,
        status TEXT NOT NULL DEFAULT 'open',
        created_at TEXT NOT NULL,
        merged_at TEXT
      )
      """,
      []
    )

    # The uniqueness that stops two branches of one database sharing a name, and so
    # sharing a cell key and a database file.
    Ecto.Adapters.SQL.query!(
      CatalogRepo,
      "CREATE UNIQUE INDEX IF NOT EXISTS branches_name ON branches (database, name)",
      []
    )

    :ok
  end

  def databases do
    CatalogRepo.all(from(d in Database, order_by: d.name))
  end

  def database(name), do: CatalogRepo.get(Database, name)

  def create_database(name) do
    CatalogRepo.insert(%Database{name: name, created_at: now()})
  end

  def branches(database) do
    CatalogRepo.all(from(b in BranchRow, where: b.database == ^database, order_by: b.created_at))
  end

  def branch(database, name) do
    CatalogRepo.one(from(b in BranchRow, where: b.database == ^database and b.name == ^name))
  end

  def open_branches do
    CatalogRepo.all(from(b in BranchRow, where: b.status == "open", order_by: b.created_at))
  end

  def record_branch(attrs) do
    %BranchRow{}
    |> Ecto.Changeset.cast(Map.put(attrs, :created_at, now()), [
      :id,
      :database,
      :name,
      :parent,
      :from_txid,
      :digest,
      :status,
      :created_at
    ])
    |> Ecto.Changeset.validate_required([:id, :database, :name, :created_at])
    |> CatalogRepo.insert()
  end

  def mark_merged(%BranchRow{} = row) do
    row
    |> Ecto.Changeset.change(status: "merged", merged_at: now())
    |> CatalogRepo.update()
  end

  def delete_branch(%BranchRow{} = row), do: CatalogRepo.delete(row)

  @doc """
  Rebuilds the `AshCell.Branch` record a merge needs from a stored row.

  The library deliberately does not persist provenance, so the application hands it
  back. A row with no digest — a root branch — has nothing to merge into and is
  refused here rather than deeper down.
  """
  def to_record(%BranchRow{parent: nil}), do: {:error, :root_branch}

  def to_record(%BranchRow{} = row) do
    {:ok,
     %AshCell.Branch{
       origin: Branch.Cells.key(row.database, row.parent),
       branch: Branch.Cells.key(row.database, row.name),
       from_txid: row.from_txid,
       requested_txid: row.from_txid,
       exact?: true,
       digest: row.digest,
       bytes: 0
     }}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
