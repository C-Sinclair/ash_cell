defmodule Branch.ServiceTest do
  @moduledoc """
  The round trip the demo exists to show: provision, branch, diverge, promote — and
  the refusal when promoting would discard the parent's writes.

  Against a real object store, because a branch *is* a snapshot and a mock of the
  snapshot history would only confirm our own reading of it.

  The library-level claims (fork isolation, txid namespaces, the fast-forward rule,
  and the measured reason divergence is a content digest rather than SQLite's change
  counter) live in `ash_cell/test/branch_test.exs`. This file only covers what the
  control plane adds on top: provenance outside both cells, and the wiring.
  """
  use ExUnit.Case, async: false

  alias Branch.{Catalog, Cells, Service}

  setup_all do
    case AshCell.ObjectStore.list(Cells.store(), "healthcheck/") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise """
        object store unreachable at #{Cells.store().endpoint} (#{inspect(reason)})

        This demo cannot run without one -- a branch is a copy of a snapshot.

            cd ../.. && scripts/minio.sh
            mc mb ashcell/ashcell-branch-test
        """
    end
  end

  setup do
    # Wall-clock, not a counter: the bucket outlives the VM, so a name built from
    # `unique_integer/1` alone inherits a previous run's lease and snapshots.
    name = "db#{System.system_time(:nanosecond)}#{System.unique_integer([:positive])}"
    {:ok, database: name}
  end

  defp sql(database, branch, statement), do: Service.query(database, branch, statement)

  defp seed(database, branch) do
    {:ok, _} = sql(database, branch, "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
    {:ok, _} = sql(database, branch, "INSERT INTO users (id, email) VALUES (1, 'ada@x.dev')")
  end

  defp emails(database, branch) do
    {:ok, %{rows: rows}} = sql(database, branch, "SELECT email FROM users ORDER BY email")
    List.flatten(rows)
  end

  test "provisioning ships once, so the database can be branched immediately", %{database: db} do
    {:ok, _} = Service.provision(db)

    # A database that has never shipped cannot be branched, and the failure would
    # surface at the first branch attempt for a reason the user cannot see.
    {:ok, history} = Service.history(db, "main")
    assert length(history) >= 1
  end

  test "a branch diverges from its parent in both directions", %{database: db} do
    {:ok, _} = Service.provision(db)
    seed(db, "main")

    {:ok, _} = Service.create_branch(db, "main", "feature")

    {:ok, _} = sql(db, "feature", "INSERT INTO users (id, email) VALUES (2, 'grace@x.dev')")
    {:ok, _} = sql(db, "main", "INSERT INTO users (id, email) VALUES (3, 'linus@x.dev')")

    assert emails(db, "feature") == ["ada@x.dev", "grace@x.dev"]
    assert emails(db, "main") == ["ada@x.dev", "linus@x.dev"]
  end

  test "a schema change on a branch does not reach the parent", %{database: db} do
    {:ok, _} = Service.provision(db)
    seed(db, "main")
    {:ok, _} = Service.create_branch(db, "main", "migration")

    {:ok, _} = sql(db, "migration", "ALTER TABLE users ADD COLUMN name TEXT")

    assert {:ok, _} = sql(db, "migration", "SELECT name FROM users")
    assert {:error, message} = sql(db, "main", "SELECT name FROM users")
    assert message =~ "no such column"
  end

  test "merging an unmoved parent fast-forwards it", %{database: db} do
    {:ok, _} = Service.provision(db)
    seed(db, "main")
    {:ok, _} = Service.create_branch(db, "main", "feature")
    {:ok, _} = sql(db, "feature", "INSERT INTO users (id, email) VALUES (2, 'grace@x.dev')")

    {:ok, result} = Service.merge(db, "feature")

    assert result.shipped?
    assert emails(db, "main") == ["ada@x.dev", "grace@x.dev"]
    assert Catalog.branch(db, "feature").status == "merged"
  end

  test "merging a parent that has moved is refused, and nothing is lost", %{database: db} do
    # The demo's point. A fast-forward here would silently discard the parent's row.
    {:ok, _} = Service.provision(db)
    seed(db, "main")
    {:ok, _} = Service.create_branch(db, "main", "feature")

    {:ok, _} = sql(db, "feature", "INSERT INTO users (id, email) VALUES (2, 'grace@x.dev')")
    {:ok, _} = sql(db, "main", "INSERT INTO users (id, email) VALUES (3, 'linus@x.dev')")

    assert {:error, {:not_fast_forward, details}} = Service.merge(db, "feature")
    assert details.origin_digest != details.branch_forked_at

    assert emails(db, "main") == ["ada@x.dev", "linus@x.dev"]
    assert emails(db, "feature") == ["ada@x.dev", "grace@x.dev"]
    assert Catalog.branch(db, "feature").status == "open"
  end

  test "a branch cut from an older snapshot does not see later writes", %{database: db} do
    {:ok, _} = Service.provision(db)
    seed(db, "main")
    {:ok, %{txid: early}} = Service.snapshot(db, "main")

    {:ok, _} = sql(db, "main", "INSERT INTO users (id, email) VALUES (2, 'later@x.dev')")
    {:ok, _} = Service.snapshot(db, "main")

    {:ok, record} = Service.create_branch(db, "main", "rewind", early)

    assert record.from_txid == early
    assert emails(db, "rewind") == ["ada@x.dev"]
  end

  test "provenance lives outside both cells, so a branch does not inherit its own record",
       %{database: db} do
    {:ok, _} = Service.provision(db)
    seed(db, "main")
    {:ok, _} = Service.create_branch(db, "main", "feature")

    row = Catalog.branch(db, "feature")
    assert row.parent == "main"
    assert row.digest

    # A provenance row written *inside* the parent would have been copied into the
    # branch, and the branch would carry a record claiming to be its own parent.
    assert {:error, message} = sql(db, "feature", "SELECT * FROM branches")
    assert message =~ "no such table"
  end

  test "dropping a branch removes its file and its snapshots, and leaves the parent alone",
       %{database: db} do
    {:ok, _} = Service.provision(db)
    seed(db, "main")
    {:ok, _} = Service.create_branch(db, "main", "scratch")
    {:ok, _} = sql(db, "scratch", "INSERT INTO users (id, email) VALUES (2, 'temp@x.dev')")
    {:ok, _} = Service.snapshot(db, "scratch")

    key = Cells.key(db, "scratch")
    {:ok, _} = Service.drop_branch(db, "scratch")

    refute File.exists?(AshCell.path_for(key))

    assert {:ok, []} =
             AshCell.ObjectStore.list(Cells.store(), AshCell.Replicator.snapshot_prefix(key))

    refute Catalog.branch(db, "scratch")
    assert emails(db, "main") == ["ada@x.dev"]
  end

  test "two branches of one database are two files, not one", %{database: db} do
    # The encoding is injective, so keys that differ produce filenames that differ.
    # Sanitising instead of escaping is what would collapse them into one database.
    {:ok, _} = Service.provision(db)
    seed(db, "main")
    {:ok, _} = Service.create_branch(db, "main", "a:b")
    {:ok, _} = Service.create_branch(db, "main", "a_b")

    {:ok, _} = sql(db, "a:b", "INSERT INTO users (id, email) VALUES (2, 'colon@x.dev')")

    assert emails(db, "a:b") == ["ada@x.dev", "colon@x.dev"]
    assert emails(db, "a_b") == ["ada@x.dev"]
  end
end
