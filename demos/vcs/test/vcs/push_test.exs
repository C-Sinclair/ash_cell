defmodule Vcs.PushTest do
  @moduledoc """
  The server side of push: what it stores, what it refuses, and what happens when two clients
  push at once.
  """
  use Vcs.Test.RepoCase, async: false

  alias Vcs.{History, Push}

  @main "refs/heads/main"

  test "a push creates the repository's cell and stores its objects", %{repo_name: repo} do
    {commit, objects} = Builder.snapshot("hello.txt", "first\n", "add hello")

    assert {:ok, 3} = Push.store(repo, objects)
    assert {:ok, ^commit} = Push.advance(repo, @main, nil, commit)

    assert Vcs.Store.Refs.all(repo) == %{@main => commit}
    assert File.exists?(AshCell.path_for(repo))
  end

  test "objects are idempotent, so a repeated push is free", %{repo_name: repo} do
    {commit, objects} = Builder.snapshot("hello.txt", "first\n", "add hello")

    assert {:ok, 3} = Push.store(repo, objects)
    assert {:ok, 3} = Push.store(repo, objects)
    assert {:ok, ^commit} = Push.advance(repo, @main, nil, commit)

    assert [_] = History.log(repo)
    assert Push.missing(repo, Enum.map(objects, & &1["id"])) == []
  end

  test "an object whose bytes do not hash to its claimed id is refused", %{repo_name: repo} do
    {_commit, [blob | rest]} = Builder.snapshot("hello.txt", "first\n", "add hello")
    lying = %{blob | "encoded_b64" => Base.encode64("blob 4" <> <<0>> <> "liar")}

    assert {:error, {:id_mismatch, _}} = Push.store(repo, [lying | rest])
  end

  test "a truncated object is refused", %{repo_name: repo} do
    {_commit, [blob | _]} = Builder.snapshot("hello.txt", "first\n", "add hello")
    encoded = Base.decode64!(blob["encoded_b64"])
    truncated = binary_part(encoded, 0, byte_size(encoded) - 2)

    # Re-id it so the hash check passes and the length check is what fires.
    id = :crypto.hash(:sha256, truncated) |> Base.encode16(case: :lower)

    assert {:error, {:malformed_object, ^id}} =
             Push.store(repo, [
               %{"id" => id, "kind" => "blob", "encoded_b64" => Base.encode64(truncated)}
             ])
  end

  test "a stale expected value is rejected with the id that actually won", %{repo_name: repo} do
    {first, first_objects} = Builder.snapshot("hello.txt", "first\n", "add hello")
    {second, second_objects} = Builder.snapshot("hello.txt", "second\n", "update hello", first)

    Push.store(repo, first_objects)
    assert {:ok, ^first} = Push.advance(repo, @main, nil, first)

    Push.store(repo, second_objects)
    assert {:ok, ^second} = Push.advance(repo, @main, first, second)

    # A client that still believes the ref is at `first` has lost a race.
    {third, third_objects} = Builder.snapshot("hello.txt", "third\n", "another update", first)
    Push.store(repo, third_objects)

    assert {:error, {:stale, ^second}} = Push.advance(repo, @main, first, third)
    assert Vcs.Store.Refs.all(repo) == %{@main => second}
  end

  test "a commit that is not a descendant of the server tip is refused", %{repo_name: repo} do
    {first, first_objects} = Builder.snapshot("a.txt", "a\n", "first")
    {unrelated, unrelated_objects} = Builder.snapshot("b.txt", "b\n", "unrelated root")

    Push.store(repo, first_objects)
    Push.advance(repo, @main, nil, first)
    Push.store(repo, unrelated_objects)

    assert {:error, {:non_fast_forward, ^first}} = Push.advance(repo, @main, first, unrelated)
  end

  test "a ref creation loses cleanly when another client created it first", %{repo_name: repo} do
    {first, first_objects} = Builder.snapshot("a.txt", "a\n", "first")
    {other, other_objects} = Builder.snapshot("b.txt", "b\n", "other first")

    Push.store(repo, first_objects)
    Push.store(repo, other_objects)

    assert {:ok, ^first} = Push.advance(repo, @main, nil, first)
    # `nil` means "I believe this ref does not exist". It does now, so this must fail rather
    # than silently no-op into looking like a win.
    assert {:error, {:stale, ^first}} = Push.advance(repo, @main, nil, other)
  end

  test "concurrent pushes to one repository leave exactly one winner", %{repo_name: repo} do
    {base, base_objects} = Builder.snapshot("a.txt", "a\n", "base")
    Push.store(repo, base_objects)
    Push.advance(repo, @main, nil, base)

    contenders =
      for n <- 1..12 do
        {id, objects} = Builder.snapshot("a.txt", "version #{n}\n", "update #{n}", base)
        Push.store(repo, objects)
        id
      end

    results =
      contenders
      |> Task.async_stream(fn id -> Push.advance(repo, @main, base, id) end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    winners = Enum.filter(results, &match?({:ok, _}, &1))
    losers = Enum.filter(results, &match?({:error, {:stale, _}}, &1))

    assert length(winners) == 1, "expected one winner, got #{inspect(results)}"
    assert length(losers) == 11

    [{:ok, winner}] = winners
    assert Vcs.Store.Refs.all(repo) == %{@main => winner}

    # Every loser was told what it lost to, not merely that it lost.
    for {:error, {:stale, current}} <- losers do
      assert current == winner
    end
  end

  test "fetch returns the closure of what the client wants and lacks", %{repo_name: repo} do
    {first, first_objects} = Builder.snapshot("a.txt", "a\n", "first")
    {second, second_objects} = Builder.snapshot("a.txt", "b\n", "second", first)

    Push.store(repo, first_objects)
    Push.advance(repo, @main, nil, first)
    Push.store(repo, second_objects)
    Push.advance(repo, @main, first, second)

    everything = Push.closure(repo, [second], [])
    # Two commits, two trees, two blobs.
    assert length(everything) == 6

    ids = Enum.map(first_objects, & &1["id"])
    incremental = Push.closure(repo, [second], ids)

    assert length(incremental) == 3
    assert Enum.all?(incremental, &(&1.id not in ids))
    assert Enum.all?(incremental, &match?(%{encoded_b64: _}, &1))
  end
end
