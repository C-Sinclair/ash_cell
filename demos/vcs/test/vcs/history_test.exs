defmodule Vcs.HistoryTest do
  @moduledoc """
  History as queries.

  These are the questions a Git server cannot answer without walking every object, and a
  client cannot answer at all without cloning first.
  """
  use Vcs.Test.RepoCase, async: false

  alias Vcs.{History, Push}

  @main "refs/heads/main"

  setup %{repo_name: repo} do
    # Three commits. `lib/a.ex` changes in the first and third; `lib/b.ex` only in the second.
    first = commit_with(repo, [{"lib/a.ex", "a1"}], "add a", nil)
    second = commit_with(repo, [{"lib/a.ex", "a1"}, {"lib/b.ex", "b1"}], "add b", first)
    third = commit_with(repo, [{"lib/a.ex", "a2"}, {"lib/b.ex", "b1"}], "change a", second)

    {:ok, ^third} = Push.advance(repo, @main, nil, third)

    {:ok, commits: %{first: first, second: second, third: third}}
  end

  test "log walks the projected parent chain, newest first", %{repo_name: repo, commits: c} do
    assert Enum.map(History.log(repo), & &1.id) == [c.third, c.second, c.first]
    assert Enum.map(History.log(repo), & &1.message) == ["change a", "add b", "add a"]
  end

  test "log respects a limit", %{repo_name: repo, commits: c} do
    assert Enum.map(History.log(repo, limit: 2), & &1.id) == [c.third, c.second]
  end

  test "path history reports the commits that changed a path, not the ones that contain it", %{
    repo_name: repo,
    commits: c
  } do
    # lib/b.ex appears in the second commit and is untouched by the third, even though the
    # third's snapshot still lists it.
    assert Enum.map(History.touching(repo, "lib/b.ex"), & &1.id) == [c.second]

    # lib/a.ex is added in the first and edited in the third; the second leaves it alone.
    assert Enum.map(History.touching(repo, "lib/a.ex"), & &1.id) == [c.third, c.first]

    assert History.touching(repo, "does/not/exist.ex") == []
  end

  test "messages are searchable without a clone", %{repo_name: repo, commits: c} do
    assert Enum.map(History.search(repo, "add"), & &1.id) == [c.second, c.first]
    assert Enum.map(History.search(repo, "CHANGE"), & &1.id) == [c.third]
    assert History.search(repo, "nothing matches this") == []
  end

  test "the tip's tree is readable directly", %{repo_name: repo, commits: c} do
    assert History.tip(repo) == c.third
    assert Enum.map(History.paths(repo), & &1.path) == ["lib/a.ex", "lib/b.ex"]
  end

  defp commit_with(repo, files, message, parent) do
    blobs =
      Enum.map(files, fn {path, contents} ->
        {path, contents, Builder.blob(contents)}
      end)

    tree =
      Builder.tree(
        Enum.map(blobs, fn {path, contents, blob} ->
          %{path: path, blob: blob.id, size: byte_size(contents)}
        end)
      )

    commit = Builder.commit(%{tree: tree.id, parent: parent, message: message})

    objects =
      Enum.map(blobs, fn {_, _, blob} -> Builder.wire(blob) end) ++
        [Builder.wire(tree), Builder.wire(commit)]

    {:ok, _} = Push.store(repo, objects)

    commit.id
  end
end
