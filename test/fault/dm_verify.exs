# The verdict half of ADR-20 tier 3, run once per replayed flush boundary by
# scripts/dm_log_writes_test.sh against a filesystem reconstructed from the block
# log. Exits non-zero if this crash state is one the design forbids.
#
# What is asserted, and what deliberately is not:
#
#   * The database must open and pass integrity_check. Required at EVERY
#     boundary. A power failure may lose recent commits; it may never leave a
#     database that cannot be read.
#   * The surviving rows must be a PREFIX of the acknowledged sequence. This is
#     the assertion tiers 1 and 2 cannot make, because it is about ordering that
#     only the block layer reveals: commits 1, 2 and 4 surviving without 3 means
#     writes were reordered across a barrier, and a reader would see a hole in a
#     sequence the application was told was durable.
#   * NOT that a particular commit survived. Which commits are durable at an
#     arbitrary flush boundary depends on the durability level and on where the
#     cut fell -- that is tier 1 and tier 2's question, asked where the
#     acknowledgement is visible. Here the ordering is the invariant.

dir = System.fetch_env!("PROBE_CELL_DIR")
ack_file = System.get_env("PROBE_ACK_FILE", "/tmp/ash_cell_dm/acknowledged.txt")

defmodule DmVerify do
  def fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  def surviving(db) do
    {:ok, conn} = Exqlite.Sqlite3.open(db)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "PRAGMA integrity_check")

      case Exqlite.Sqlite3.step(conn, stmt) do
        {:row, ["ok"]} -> :ok
        other -> fail("integrity_check failed: #{inspect(other)}")
      end

      case Exqlite.Sqlite3.prepare(conn, "SELECT name FROM tenant_patients") do
        {:ok, stmt} ->
          {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
          List.flatten(rows)

        # The cut landed before the migration was durable. A database with no
        # table yet is a valid crash state, not a failure.
        #
        # `tenant_patients`, not `patients`: both exist after the migration, and
        # querying the wrong one returns an empty result that reads as data loss.
        _ ->
          []
      end
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  # A prefix, not a subset. `Patient 1, 2, 4` is a hole, and a hole means a write
  # crossed a barrier it should not have.
  def assert_prefix!(survivors, acknowledged) do
    expected = Enum.take(acknowledged, length(survivors))

    if MapSet.new(survivors) != MapSet.new(expected) do
      fail("""
      surviving commits are not a prefix of the acknowledged sequence.

        surviving: #{inspect(Enum.sort(survivors))}
        expected a prefix of: #{inspect(acknowledged)}

      A gap here means writes were reordered across a barrier: the database
      contains a later commit while an earlier one is missing.
      """)
    end
  end
end

case Path.wildcard(Path.join(dir, "**/*.db")) do
  [] ->
    # No cell file yet at this boundary. Nothing to check, and not a failure.
    IO.puts("no database at this boundary")

  [db | _] ->
    acknowledged = ack_file |> File.read!() |> String.split("\n", trim: true)
    survivors = DmVerify.surviving(db)
    DmVerify.assert_prefix!(survivors, acknowledged)
    IO.puts("ok -- #{length(survivors)}/#{length(acknowledged)} commits survived, in order")
end
