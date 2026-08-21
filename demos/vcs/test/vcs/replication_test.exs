defmodule Vcs.ReplicationTest do
  @moduledoc """
  Point-in-time restore for one repository.

  Git's answer to "restore this project to how it looked on Tuesday" is to restore the whole
  forge's filesystem. A repository that is a single file has a per-repository answer, and the
  object store keeps a generation per snapshot.

  Tagged `:minio` and excluded by default. Start one with:

      minio server /tmp/ashcell-minio --address :9010
      mc alias set ashcell http://127.0.0.1:9010 ashcell ashcellsecret
      mc mb ashcell/ashcell-test
  """
  use Vcs.Test.RepoCase, async: false

  @moduletag :minio

  alias AshCell.Replicator
  alias Vcs.{History, Push}

  @main "refs/heads/main"

  setup %{repo_name: repo} do
    store = AshCell.ObjectStore.new(Application.fetch_env!(:vcs, :object_store))

    case AshCell.ObjectStore.list(store, "healthcheck/") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise "MinIO unreachable at #{store.endpoint} (#{inspect(reason)}); see the moduledoc"
    end

    on_exit(fn ->
      for key <- elem(AshCell.ObjectStore.list(store, Replicator.snapshot_prefix(repo)), 1) do
        AshCell.ObjectStore.delete(store, key)
      end
    end)

    {:ok, store: store}
  end

  test "a repository destroyed on disk comes back from its snapshot", %{
    repo_name: repo,
    store: store
  } do
    {first, first_objects} = Builder.snapshot("a.txt", "one\n", "first commit")
    Push.store(repo, first_objects)
    Push.advance(repo, @main, nil, first)

    assert {:ok, %{txid: 1, bytes: bytes}} = Replicator.snapshot(store, repo, 1)
    assert bytes > 0

    # Everything after this point is what the snapshot must *not* contain.
    {second, second_objects} = Builder.snapshot("a.txt", "two\n", "second commit", first)
    Push.store(repo, second_objects)
    Push.advance(repo, @main, first, second)
    assert length(History.log(repo)) == 2

    AshCell.close(repo)
    path = AshCell.path_for(repo)
    for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    refute File.exists?(path)

    assert {:ok, %{txid: 1}} = Replicator.restore(store, repo, 1)

    # Restored to the moment of the snapshot: the first commit, and not the second.
    assert Enum.map(History.log(repo), & &1.message) == ["first commit"]
    assert Vcs.Store.Refs.all(repo) == %{@main => first}
    assert Push.missing(repo, [second]) == [second]
  end

  test "restore picks the newest generation when not told which", %{
    repo_name: repo,
    store: store
  } do
    {first, first_objects} = Builder.snapshot("a.txt", "one\n", "first commit")
    Push.store(repo, first_objects)
    Push.advance(repo, @main, nil, first)
    {:ok, _} = Replicator.snapshot(store, repo, 1)

    {second, second_objects} = Builder.snapshot("a.txt", "two\n", "second commit", first)
    Push.store(repo, second_objects)
    Push.advance(repo, @main, first, second)
    {:ok, _} = Replicator.snapshot(store, repo, 2)

    assert {:ok, 2} = Replicator.newest_snapshot(store, repo)

    AshCell.close(repo)
    File.rm!(AshCell.path_for(repo))

    assert {:ok, %{txid: 2}} = Replicator.restore(store, repo)
    assert Enum.map(History.log(repo), & &1.message) == ["second commit", "first commit"]
  end

  test "the snapshot in the bucket is the encrypted file, not a plaintext export", %{
    repo_name: repo,
    store: store
  } do
    {commit, objects} = Builder.snapshot("secret.txt", "BUCKET-SECRET-MARKER\n", "add secret")
    Push.store(repo, objects)
    Push.advance(repo, @main, nil, commit)

    {:ok, _} = Replicator.snapshot(store, repo, 1)
    {:ok, bytes, _etag} = AshCell.ObjectStore.get(store, Replicator.snapshot_key(repo, 1))

    refute String.starts_with?(bytes, "SQLite format 3")
    refute bytes =~ "BUCKET-SECRET-MARKER"
    refute bytes =~ "secret.txt"
  end
end
