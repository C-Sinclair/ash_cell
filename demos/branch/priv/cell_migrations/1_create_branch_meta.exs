defmodule Branch.CellMigrations.CreateBranchMeta do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE _branch_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    """)
  end
end
