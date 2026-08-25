defmodule AshCell.BranchTest do
  @moduledoc """
  Branching, and the refusals that make it honest.

  The claims under test are narrow on purpose. A fork is genuinely isolated in both
  directions, because it is a second file with a second connection. A merge is a
  fast-forward or it is refused, because two divergent SQLite databases have no
  reconciliation that is not a domain rule — see
  [ADR-23](../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md).

  The load-bearing test in here is `refuses a merge when the origin has advanced`.
  Everything else could be right and that one wrong, and the failure mode would be
  silent data loss on the origin.

  Against a real bucket, not a mock: fork reads a snapshot the replicator wrote and
  merge ships one back, so a mock would only confirm our reading of the key layout.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.{Branch, History, Lease, Replicator}

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_branch_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.TestMigrations,
       store: store,
       owner: "node-a",
       snapshot: false}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp adopt(store, cell) do
    {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
    :ok = AshCell.Manager.put_lease(cell, lease)
    lease
  end

  # Deliberately raw SQL against the cell's own repo pid rather than an Ash
  # resource. Branching sits *below* the data layer -- it moves whole database
  # files -- so driving it through the resource path would couple these tests to
  # the tenancy runtime without testing anything more about branching.
  defp repo_pid(cell) do
    {:ok, pid} = AshCell.Manager.ensure_started(cell)
    AshCell.Cell.repo_pid(pid)
  end

  defp write(cell, name) do
    Ecto.Adapters.SQL.query!(
      repo_pid(cell),
      "INSERT INTO tenant_patients (id, name) VALUES (?1, ?2)",
      [Ecto.UUID.generate(), name]
    )
  end

  defp names(cell) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo_pid(cell), "SELECT name FROM tenant_patients", [])

    rows |> List.flatten() |> Enum.sort()
  end

  # An origin with one shipped snapshot: the ordinary starting point for a branch.
  defp origin_with(store, prefix, names) do
    cell = unique_cell(prefix)
    adopt(store, cell)
    for name <- names, do: write(cell, name)
    {:ok, %{txid: txid}} = Replicator.ship(store, cell)
    {cell, txid}
  end

  describe "history" do
    test "lists the snapshots that exist, in txid order", %{store: store} do
      {cell, _} = origin_with(store, "hist_list", ["A"])
      write(cell, "B")
      {:ok, _} = Replicator.ship(store, cell)

      {:ok, snapshots} = History.list(store, cell)

      assert Enum.map(snapshots, & &1.txid) == [1, 2]
      assert Enum.all?(snapshots, &(&1.bytes > 0))
    end

    test "resolves an inexact txid down, and says it was inexact", %{store: store} do
      {cell, _} = origin_with(store, "hist_resolve", ["A"])
      write(cell, "B")
      {:ok, _} = Replicator.ship(store, cell)

      assert {:ok, %{resolved: 1, exact?: true}} = History.resolve(store, cell, 1)
      assert {:ok, %{resolved: 2, exact?: true}} = History.resolve(store, cell, :latest)
    end

    test "refuses a txid older than the oldest snapshot retained", %{store: store} do
      {cell, _} = origin_with(store, "hist_expired", ["A"])
      # Standing in for a bucket lifecycle rule having expired early history: the
      # cell has snapshots, just none at or before the requested point.
      :ok = AshCell.ObjectStore.delete(store, Replicator.snapshot_key(cell, 1))
      write(cell, "B")
      {:ok, _} = Replicator.ship(store, cell)

      assert {:error, {:no_snapshot_at_or_before, _}} = History.resolve(store, cell, 1)
    end

    test "a cell that never shipped is not found, rather than txid zero", %{store: store} do
      assert {:error, :not_found} = History.resolve(store, unique_cell("hist_never"), :latest)
    end
  end

  describe "the divergence digest" do
    test "is stable across a shipment and moves on a write", %{store: store} do
      {cell, _} = origin_with(store, "digest", ["A"])
      {:ok, before} = History.digest_at(AshCell.path_for(cell))

      # A snapshot advances the txid. If the fast-forward test were built on txid
      # this is where it would start refusing merges that have no conflict.
      {:ok, %{txid: shipped_txid}} = Replicator.ship(store, cell)
      {:ok, after_ship} = History.digest_at(AshCell.path_for(cell))

      write(cell, "B")
      :ok = AshCell.checkpoint_cell(cell)
      {:ok, after_write} = History.digest_at(AshCell.path_for(cell))

      assert shipped_txid == 2
      assert after_ship == before
      assert after_write != before
    end

    test "SQLite's change counter would not have worked, which is why it is not used",
         %{store: store} do
      # Kept as a test because it was believed, acted on, and measured false. In WAL
      # mode the header's change counter does not move per transaction, so a
      # fast-forward test built on it reports "no divergence" for a database that has
      # been rewritten -- and merge then discards the origin's writes silently.
      {cell, _} = origin_with(store, "counter_myth", ["A"])

      counter = fn ->
        <<_::binary-size(24), c::big-32, _::binary>> =
          AshCell.path_for(cell) |> File.read!() |> binary_part(0, 100)

        c
      end

      before = counter.()
      write(cell, "B")
      :ok = AshCell.checkpoint_cell(cell)

      assert counter.() == before
    end
  end

  describe "fork" do
    test "copies the origin at a txid and diverges in both directions", %{store: store} do
      {origin, txid} = origin_with(store, "fork_iso", ["Ada"])
      branch = unique_cell("fork_iso_b")

      {:ok, record} = Branch.fork(store, origin, to: branch, from: txid)
      adopt(store, branch)

      assert record.from_txid == txid
      assert record.exact?
      assert names(branch) == ["Ada"]

      write(branch, "Grace")
      write(origin, "Linus")

      assert names(branch) == ["Ada", "Grace"]
      assert names(origin) == ["Ada", "Linus"]
    end

    test "gets its own txid namespace, not a continuation of the origin's", %{store: store} do
      {origin, _} = origin_with(store, "fork_txid", ["A"])
      write(origin, "B")
      {:ok, %{txid: 2}} = Replicator.ship(store, origin)

      branch = unique_cell("fork_txid_b")
      {:ok, _record} = Branch.fork(store, origin, to: branch, from: 2)
      adopt(store, branch)

      # The branch is a different cell key, so it is a different snapshot prefix and
      # a different high-water mark. It starts at 1 while the origin sits at 2, and
      # neither can claim a txid the other has written.
      {:ok, %{txid: 1}} = Replicator.ship(store, branch)
      assert {:ok, 2} = Replicator.latest_txid(store, origin)
    end

    test "an inexact txid resolves down and reports the gap", %{store: store} do
      {origin, _} = origin_with(store, "fork_inexact", ["A"])
      write(origin, "B")
      {:ok, _} = Replicator.ship(store, origin)

      branch = unique_cell("fork_inexact_b")
      {:ok, record} = Branch.fork(store, origin, to: branch, from: 99)

      refute record.exact?
      assert record.requested_txid == 99
      assert record.from_txid == 2
    end

    test "refuses a key that already has a database", %{store: store} do
      {origin, txid} = origin_with(store, "fork_used", ["A"])
      {taken, _} = origin_with(store, "fork_taken", ["B"])

      assert {:error, {:key_in_use, :local_file}} =
               Branch.fork(store, origin, to: taken, from: txid)
    end

    test "refuses a key that has snapshots but no local file", %{store: store} do
      {origin, txid} = origin_with(store, "fork_remote", ["A"])
      {taken, _} = origin_with(store, "fork_remote_taken", ["B"])

      # The durable half of "used". A cell can be in the bucket and not resident
      # here, and a fork onto it would destroy it the moment it was next restored.
      {:ok, _} = AshCell.Manager.delete(taken)
      refute File.exists?(AshCell.path_for(taken))

      assert {:error, {:key_in_use, :snapshots}} =
               Branch.fork(store, origin, to: taken, from: txid)
    end

    test "refuses forking a cell onto itself", %{store: store} do
      {origin, txid} = origin_with(store, "fork_self", ["A"])
      assert {:error, :same_cell} = Branch.fork(store, origin, to: origin, from: txid)
    end

    test "a branch of a branch works, and is isolated from both", %{store: store} do
      {origin, txid} = origin_with(store, "fork_deep", ["A"])

      first = unique_cell("fork_deep_1")
      {:ok, _} = Branch.fork(store, origin, to: first, from: txid)
      adopt(store, first)
      write(first, "B")
      {:ok, %{txid: first_txid}} = Replicator.ship(store, first)

      second = unique_cell("fork_deep_2")
      {:ok, _} = Branch.fork(store, first, to: second, from: first_txid)
      adopt(store, second)
      write(second, "C")

      assert names(origin) == ["A"]
      assert names(first) == ["A", "B"]
      assert names(second) == ["A", "B", "C"]
    end
  end

  describe "merge" do
    test "fast-forwards an origin that has not moved", %{store: store} do
      {origin, txid} = origin_with(store, "merge_ff", ["Ada"])
      branch = unique_cell("merge_ff_b")

      {:ok, record} = Branch.fork(store, origin, to: branch, from: txid)
      adopt(store, branch)
      write(branch, "Grace")

      {:ok, result} = Branch.merge(store, record)

      assert result.shipped?
      assert names(origin) == ["Ada", "Grace"]
    end

    test "the merged state is what the bucket holds, not just what is on disk",
         %{store: store} do
      {origin, txid} = origin_with(store, "merge_durable", ["Ada"])
      branch = unique_cell("merge_durable_b")

      {:ok, record} = Branch.fork(store, origin, to: branch, from: txid)
      adopt(store, branch)
      write(branch, "Grace")

      {:ok, %{txid: merged_txid}} = Branch.merge(store, record)

      # Destroy the local file and bring the origin back from the shipment the merge
      # made. If merge had only written locally, this is where the merge disappears.
      {:ok, _} = AshCell.Manager.delete(origin)
      {:ok, _} = Replicator.restore(store, origin, merged_txid)

      assert names(origin) == ["Ada", "Grace"]
    end

    test "refuses a merge when the origin has advanced, and names both counters",
         %{store: store} do
      # The test this module exists for. A fast-forward here would silently discard
      # the origin's own write.
      {origin, txid} = origin_with(store, "merge_diverged", ["Ada"])
      branch = unique_cell("merge_diverged_b")

      {:ok, record} = Branch.fork(store, origin, to: branch, from: txid)
      adopt(store, branch)
      write(branch, "Grace")
      write(origin, "Linus")

      assert {:error, {:not_fast_forward, details}} = Branch.merge(store, record)
      assert details.origin_digest != details.branch_forked_at

      # The origin is untouched by the refusal -- not partly merged, not closed out.
      assert names(origin) == ["Ada", "Linus"]
      assert names(branch) == ["Ada", "Grace"]
    end

    test "a shipment on the origin does not by itself refuse the merge", %{store: store} do
      # The counterpart to the refusal above: shipping is not writing, and a periodic
      # snapshot on an otherwise idle origin must not block a legal fast-forward.
      {origin, txid} = origin_with(store, "merge_idle_ship", ["Ada"])
      branch = unique_cell("merge_idle_ship_b")

      {:ok, record} = Branch.fork(store, origin, to: branch, from: txid)
      adopt(store, branch)
      write(branch, "Grace")

      {:ok, _} = Replicator.ship(store, origin)

      assert {:ok, _} = Branch.merge(store, record)
      assert names(origin) == ["Ada", "Grace"]
    end

    test "refuses when this node does not hold the origin's lease", %{store: store} do
      {origin, txid} = origin_with(store, "merge_unowned", ["Ada"])
      branch = unique_cell("merge_unowned_b")

      {:ok, record} = Branch.fork(store, origin, to: branch, from: txid)
      adopt(store, branch)
      write(branch, "Grace")

      # Losing the cell to another node. Writing the origin's file from here is
      # exactly what fencing exists to stop.
      :ok = AshCell.Manager.put_lease(origin, nil)

      assert {:error, :not_owner} = Branch.merge(store, record)
    end
  end

  describe "drop" do
    test "removes the branch's database and its snapshots", %{store: store} do
      {origin, txid} = origin_with(store, "drop", ["Ada"])
      branch = unique_cell("drop_b")

      {:ok, record} = Branch.fork(store, origin, to: branch, from: txid)
      adopt(store, branch)
      write(branch, "Grace")
      {:ok, _} = Replicator.ship(store, branch)

      {:ok, dropped} = Branch.drop(store, record)

      assert dropped.snapshots == 1
      refute File.exists?(AshCell.path_for(branch))
      assert {:ok, []} = AshCell.ObjectStore.list(store, Replicator.snapshot_prefix(branch))

      # The origin is untouched by dropping a branch of it.
      assert names(origin) == ["Ada"]
    end
  end
end
