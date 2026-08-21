defmodule Vcs.Store do
  @moduledoc """
  The contents of one repository.

  Note what is *not* on these resources: no `repo_id` column, and no filter on one. The
  repository **is** the database. There is no shared table for a missing `WHERE` clause to
  leak across, and no way to accidentally serve one project's objects to another.
  """
  use Ash.Domain

  resources do
    resource(Vcs.Store.Object)
    resource(Vcs.Store.Commit)
    resource(Vcs.Store.CommitPath)
    resource(Vcs.Store.Ref)
  end
end

defmodule Vcs.Store.Object do
  @moduledoc """
  One immutable, content-addressed object: a blob, a tree, or a commit.

  `body` is the full encoded bytes, header included, exactly as the client hashed them. The
  server stores what it was given and recomputes the id, so it never has to trust the client's
  arithmetic.
  """
  use Ash.Resource,
    domain: Vcs.Store,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("objects")
    repo(Vcs.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:kind, :string, allow_nil?: false, public?: true)
    attribute(:size, :integer, allow_nil?: false, public?: true)
    attribute(:body, :binary, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:id, :kind, :size, :body]])
  end

  code_interface do
    define(:create)
    define(:read)
  end
end

defmodule Vcs.Store.Commit do
  @moduledoc """
  A commit, unpacked into columns.

  The commit object in `objects` is the authority — this row is a projection of it, written at
  push time so that history is queryable without decoding anything.
  """
  use Ash.Resource,
    domain: Vcs.Store,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("commits")
    repo(Vcs.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:parent_id, :string, public?: true)
    attribute(:tree_id, :string, allow_nil?: false, public?: true)
    attribute(:message, :string, allow_nil?: false, public?: true)
    attribute(:author, :string, public?: true)
    attribute(:committed_at, :string, allow_nil?: false, public?: true)
  end

  relationships do
    has_many(:paths, Vcs.Store.CommitPath, destination_attribute: :commit_id)
  end

  actions do
    defaults([
      :read,
      create: [:id, :parent_id, :tree_id, :message, :author, :committed_at]
    ])
  end

  code_interface do
    define(:create)
    define(:read)
  end
end

defmodule Vcs.Store.CommitPath do
  @moduledoc "One path in one commit's snapshot. The tree, flattened for querying."
  use Ash.Resource,
    domain: Vcs.Store,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("commit_paths")
    repo(Vcs.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:commit_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:path, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:blob_id, :string, allow_nil?: false, public?: true)
    attribute(:size, :integer, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to :commit, Vcs.Store.Commit do
      source_attribute(:commit_id)
      destination_attribute(:id)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read, create: [:commit_id, :path, :blob_id, :size]])
  end

  code_interface do
    define(:create)
    define(:read)
  end
end

defmodule Vcs.Store.Ref do
  @moduledoc """
  A branch tip.

  Reads go through Ash; the *write* does not — see `Vcs.Store.Refs`. Advancing a ref is a
  compare-and-set, and AshSqlite reports `can?(:transact) → false`, so the CAS is expressed as
  a single conditional `UPDATE` rather than a read-then-write in an Ash action.
  """
  use Ash.Resource,
    domain: Vcs.Store,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("refs")
    repo(Vcs.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:commit_id, :string, allow_nil?: false, public?: true)
    attribute(:updated_at, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:name, :commit_id, :updated_at]])
  end

  code_interface do
    define(:read)
  end
end
