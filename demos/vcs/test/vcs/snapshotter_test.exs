defmodule Vcs.SnapshotterTest do
  @moduledoc """
  The periodic snapshot loop.

  Tagged `:minio` like the rest of the replication tests — the whole point is the conditional
  write, and a mock of that would only confirm our own understanding of it.
  """
  use Vcs.Test.RepoCase, async: false

  @moduletag :minio

  alias AshCell.Replicator
  alias Vcs.{Push, Snapshotter}

  @main "refs/heads/main"

  setup %{repo_name: repo} do
    store = AshCell.ObjectStore.new(Application.fetch_env!(:vcs, :object_store))

    case AshCell.ObjectStore.list(store, "healthcheck/") do
      {:ok, _} -> :ok
      {:error, reason} -> raise "MinIO unreachable (#{inspect(reason)}); see the moduledoc"
    end

    on_exit(fn ->
      {:ok, keys} = AshCell.ObjectStore.list(store, "cells/#{repo}/")
      for key <- keys, do: AshCell.ObjectStore.delete(store, key)
    end)

    {:ok, store: store}
  end

  describe "generation composition" do
    test "a later tick outranks an earlier one" do
      assert Snapshotter.generation(1, 1) < Snapshotter.generation(1, 2)
    end

    test "a new epoch outranks every tick the previous epoch could reach" do
      # This is the property that makes `restore(:latest)` correct after a takeover: a fenced
      # predecessor cannot write a key that beats its successor's first one.
      assert Snapshotter.generation(5, 999_999) < Snapshotter.generation(6, 1)
    end
  end

  describe "sweeping" do
    setup %{repo_name: repo} do
      {commit, objects} = Builder.snapshot("a.txt", "one\n", "first commit")
      Push.store(repo, objects)
      Push.advance(repo, @main, nil, commit)

      {:ok, first: commit}
    end

    test "a sweep snapshots a resident repository", %{repo_name: repo, store: store} do
      assert {:ok, taken} = Snapshotter.sweep()
      assert {^repo, generation} = Enum.find(taken, fn {name, _} -> name == repo end)

      assert {:ok, ^generation} = Replicator.newest_snapshot(store, repo)

      assert {:ok, bytes, _etag} =
               AshCell.ObjectStore.get(store, Replicator.snapshot_key(repo, generation))

      # The blob in the bucket is the encrypted file, not an export of it.
      refute String.starts_with?(bytes, "SQLite format 3")
    end

    test "an idle repository is not re-uploaded", %{repo_name: repo} do
      assert {:ok, first} = Snapshotter.sweep()
      assert Enum.any?(first, fn {name, _} -> name == repo end)

      # Nothing has been pushed in between, so there is nothing to ship.
      assert {:ok, second} = Snapshotter.sweep()
      refute Enum.any?(second, fn {name, _} -> name == repo end)
    end

    test "a repository another node holds is left alone", %{repo_name: repo, store: store} do
      # Somebody else got the lease first. This node must not snapshot under an epoch it does
      # not own, even though the cell is resident and has changed.
      {:ok, _} = AshCell.Lease.claim(store, repo, "some-other-node", ttl_ms: 60_000)

      assert {:ok, taken} = Snapshotter.sweep()
      refute Enum.any?(taken, fn {name, _} -> name == repo end)
      assert Replicator.newest_snapshot(store, repo) == {:error, :not_found}
    end

    test "a displaced node stops snapshotting once its lease is taken", %{
      repo_name: repo,
      store: store,
      first: first
    } do
      assert {:ok, taken} = Snapshotter.sweep()
      assert Enum.any?(taken, fn {name, _} -> name == repo end)
      {:ok, ours} = Replicator.newest_snapshot(store, repo)

      # Simulate a takeover. The lease that matters is the one in the bucket, not our local
      # copy, so expire it there and let another owner claim it. We keep our stale etag, which
      # is exactly the state a node in this position is really in.
      held = AshCell.Manager.lease(repo)

      {:ok, _} =
        AshCell.ObjectStore.put(
          store,
          AshCell.Lease.key(repo),
          Jason.encode!(%{owner: held.owner, expires_at: 0, generation: held.generation}),
          if_match: held.etag
        )

      {:ok, theirs} = AshCell.Lease.claim(store, repo, "successor", ttl_ms: 60_000)
      assert theirs.generation > held.generation

      {second, objects} = Builder.snapshot("a.txt", "two\n", "second commit", first)
      Push.store(repo, objects)
      Push.advance(repo, @main, first, second)

      # Our renewal is refused because the successor holds the lease under a new etag, so we
      # write nothing rather than persisting under a generation we no longer own.
      assert {:ok, after_takeover} = Snapshotter.sweep()
      refute Enum.any?(after_takeover, fn {name, _} -> name == repo end)
      assert Replicator.newest_snapshot(store, repo) == {:ok, ours}

      # And the successor's first snapshot outranks everything we could have written.
      assert Snapshotter.generation(theirs.generation, 1) > ours
    end

    test "a push between sweeps produces a newer generation with the newer data", %{
      repo_name: repo,
      store: store,
      first: first
    } do
      assert {:ok, _} = Snapshotter.sweep()
      {:ok, early} = Replicator.newest_snapshot(store, repo)

      {second, objects} = Builder.snapshot("a.txt", "two\n", "second commit", first)
      Push.store(repo, objects)
      Push.advance(repo, @main, first, second)

      assert {:ok, taken} = Snapshotter.sweep()
      assert Enum.any?(taken, fn {name, _} -> name == repo end)
      assert {:ok, late} = Replicator.newest_snapshot(store, repo)
      assert late > early

      # Restoring the newest generation must bring back the second commit; restoring the older
      # one must not.
      AshCell.close(repo)
      File.rm!(AshCell.path_for(repo))
      assert {:ok, %{txid: ^late}} = Replicator.restore(store, repo)
      assert Enum.map(Vcs.History.log(repo), & &1.message) == ["second commit", "first commit"]

      AshCell.close(repo)
      assert {:ok, _} = Replicator.restore(store, repo, early)
      assert Enum.map(Vcs.History.log(repo), & &1.message) == ["first commit"]
    end
  end
end
