defmodule CollabEditor.Docs.Document do
  @moduledoc """
  The document's own metadata, in the document's own cell.

  There is exactly one row in this table, and its id is the document id, which is
  also the cell key's suffix. That looks redundant until you delete a document:
  `AshCell.delete/1` removes the file and the metadata goes with it, because there
  is nowhere else for it to be.
  """
  use Ash.Resource,
    domain: CollabEditor.Docs,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("document")
    repo(CollabEditor.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:created_at, :utc_datetime, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:id, :title, :created_at], update: [:title]])
  end

  code_interface do
    define(:create)
    define(:read)
    define(:update)
  end
end

defmodule CollabEditor.Docs.Update do
  @moduledoc """
  One Yjs update, as the bytes the browser produced.

  The server does not need to understand a keystroke to store one — a Yjs update
  is opaque, self-describing, and commutative. What it does need is somewhere the
  update cannot be lost, and a `seq` so a reconnecting client can ask for the tail
  instead of the document.

  `seq` is assigned by reading the head and adding one, inside a transaction on
  the cell. That is the classic lost-update race, and it is safe here for reasons
  that have nothing to do with CRDTs: one connection per document
  (`pool_size: 1`), `BEGIN IMMEDIATE` so no read-then-write has to upgrade a lock,
  and a lease so exactly one node holds the document at all.
  """
  use Ash.Resource,
    domain: CollabEditor.Docs,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("updates")
    repo(CollabEditor.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:seq, :integer, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:payload, :binary, allow_nil?: false, public?: true)
    attribute(:client_id, :string, public?: true)
    attribute(:at, :utc_datetime, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:seq, :payload, :client_id, :at]])
  end

  code_interface do
    define(:create)
    define(:read)
    define(:destroy)
  end
end

defmodule CollabEditor.Docs.Snapshot do
  @moduledoc """
  The merged state of the document up to `through_seq`, produced by compaction.

  One row, id `"current"`. A new client loads this plus whatever updates arrived
  after it, rather than replaying the document's entire history — which is what
  keeps a document that has been edited for a year as cheap to open as one written
  yesterday.
  """
  use Ash.Resource,
    domain: CollabEditor.Docs,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("snapshots")
    repo(CollabEditor.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:state, :binary, allow_nil?: false, public?: true)
    attribute(:through_seq, :integer, allow_nil?: false, public?: true)
    attribute(:updated_at, :utc_datetime, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :put do
      accept([:id, :state, :through_seq, :updated_at])
      upsert?(true)
    end
  end

  code_interface do
    define(:read)
    define(:put)
  end
end

defmodule CollabEditor.Docs do
  @moduledoc """
  Every resource here is tenanted by *document*, and lives in that document's own
  encrypted file. See `CollabEditor.CellKey` for why the cut is a document, and
  `CollabEditor.Editing` for the operations built on top.
  """
  use Ash.Domain

  resources do
    resource(CollabEditor.Docs.Document)
    resource(CollabEditor.Docs.Update)
    resource(CollabEditor.Docs.Snapshot)
  end
end
