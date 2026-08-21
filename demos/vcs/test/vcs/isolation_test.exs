defmodule Vcs.IsolationTest do
  @moduledoc """
  Isolation as a property of the storage, not of a query.

  A forge that filters by `repo_id` is one missing `WHERE` clause away from serving the wrong
  project's history. These tests read the bytes on disk directly, bypassing Ash entirely,
  because that is the only way to show the isolation is physical.
  """
  use ExUnit.Case, async: false

  alias Vcs.Test.Builder
  alias Vcs.{History, Push}

  @main "refs/heads/main"

  setup do
    suffix = System.unique_integer([:positive])
    one = "acme/secret-#{suffix}"
    two = "globex/public-#{suffix}"

    on_exit(fn ->
      AshCell.delete(one)
      AshCell.delete(two)
    end)

    {:ok, one: one, two: two}
  end

  test "two repositories are two files, and neither can see the other", %{one: one, two: two} do
    {first, first_objects} = Builder.snapshot("secret.txt", "acme confidential\n", "acme work")
    {second, second_objects} = Builder.snapshot("readme.md", "globex public\n", "globex work")

    Push.store(one, first_objects)
    Push.advance(one, @main, nil, first)
    Push.store(two, second_objects)
    Push.advance(two, @main, nil, second)

    assert AshCell.path_for(one) != AshCell.path_for(two)
    assert Enum.map(History.log(one), & &1.message) == ["acme work"]
    assert Enum.map(History.log(two), & &1.message) == ["globex work"]

    # The other repository's commit is not merely filtered out — it is not in the file.
    assert Push.missing(one, [second]) == [second]
    assert Push.missing(two, [first]) == [first]
  end

  test "a repository's file is encrypted at rest", %{one: one} do
    {commit, objects} = Builder.snapshot("secret.txt", "SUPER-SECRET-MARKER\n", "commit marker")

    Push.store(one, objects)
    Push.advance(one, @main, nil, commit)
    :ok = AshCell.checkpoint(one)

    bytes = File.read!(AshCell.path_for(one))

    # SQLite's own magic string is the cheapest possible tell that a file is not encrypted.
    refute String.starts_with?(bytes, "SQLite format 3")
    refute bytes =~ "SUPER-SECRET-MARKER"
    refute bytes =~ "commit marker"
    refute bytes =~ "secret.txt"
  end

  test "revoking one repository's key shreds that repository alone", %{one: one, two: two} do
    {first, first_objects} = Builder.snapshot("a.txt", "acme\n", "acme work")
    {second, second_objects} = Builder.snapshot("b.txt", "globex\n", "globex work")

    Push.store(one, first_objects)
    Push.advance(one, @main, nil, first)
    Push.store(two, second_objects)
    Push.advance(two, @main, nil, second)

    path = AshCell.path_for(one)
    :ok = AshCell.checkpoint(one)
    size_before = File.stat!(path).size

    :ok = Vcs.Vault.revoke(one)

    # The bytes are still there — a revocation removes no data. It may even grow, because
    # closing the cell folds the WAL into the main file on the way out. What matters is that
    # nothing was deleted and nothing is readable, which is a stronger deletion story than
    # `DELETE FROM ... WHERE repo_id = ?`.
    assert File.stat!(path).size >= size_before
    assert Vcs.Vault.fingerprint(one) == nil

    assert catch_error(History.log(one))

    # The neighbour is untouched.
    assert Enum.map(History.log(two), & &1.message) == ["globex work"]

    :ok = Vcs.Vault.unrevoke(one)
    assert Enum.map(History.log(one), & &1.message) == ["acme work"]
  end
end
