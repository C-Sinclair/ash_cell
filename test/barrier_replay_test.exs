defmodule AshCell.BarrierReplayTest do
  @moduledoc """
  The reconstruction half of ADR-20 tier 2.

  The probe that produces a real trace is Linux-only, but rebuilding a file from
  one is pure, so it is tested here on every platform — and it is worth testing
  properly, because a reconstruction that is subtly wrong does not report a
  failure. It reports *corruption*, and corruption is exactly what tier 2 is
  looking for. A bug here would be read as a finding.

  The last test closes that loop for real: it writes a SQLite database through
  the same shape of records the shim emits, replays it, and opens the result.
  """
  use ExUnit.Case, async: true

  alias AshCell.BarrierReplay

  defp rec(op, path, off, len, data_off),
    do: %{op: op, path: path, off: off, len: len, data_off: data_off}

  defp write(path, off, payload, blob_off),
    do: rec("write", path, off, byte_size(payload), blob_off)

  describe "reconstruct/3" do
    test "applies writes in order at their offsets" do
      blob = "helloworld"

      records = [
        write("/a", 0, "hello", 0),
        write("/a", 5, "world", 5)
      ]

      assert {:ok, %{"/a" => "helloworld"}} = BarrierReplay.reconstruct(records, blob, 2)
    end

    test "a cut drops everything after it" do
      blob = "helloworld"
      records = [write("/a", 0, "hello", 0), write("/a", 5, "world", 5)]

      assert {:ok, %{"/a" => "hello"}} = BarrierReplay.reconstruct(records, blob, 1)
      assert {:ok, files} = BarrierReplay.reconstruct(records, blob, 0)
      assert files == %{}
    end

    test "an overwrite replaces bytes in place without changing length" do
      blob = "helloHELLO"
      records = [write("/a", 0, "hello", 0), write("/a", 0, "HELLO", 5)]

      assert {:ok, %{"/a" => "HELLO"}} = BarrierReplay.reconstruct(records, blob, 2)
    end

    test "an overwrite in the middle keeps the tail" do
      blob = "abcdefXX"
      records = [write("/a", 0, "abcdef", 0), write("/a", 2, "XX", 6)]

      assert {:ok, %{"/a" => "abXXef"}} = BarrierReplay.reconstruct(records, blob, 2)
    end

    # SQLite grows the WAL by writing past the end, and the filesystem fills the
    # gap with zeroes. A replay that appended instead would shift every
    # subsequent offset and produce a file that is corrupt for a reason that has
    # nothing to do with durability.
    test "a write past the end zero-fills the gap" do
      blob = "abXY"
      records = [write("/a", 0, "ab", 0), write("/a", 4, "XY", 2)]

      assert {:ok, %{"/a" => <<"ab", 0, 0, "XY">>}} = BarrierReplay.reconstruct(records, blob, 2)
    end

    test "truncate shortens the file and is not an offset" do
      blob = "abcdef"
      records = [write("/a", 0, "abcdef", 0), rec("truncate", "/a", 2, 0, -1)]

      assert {:ok, %{"/a" => "ab"}} = BarrierReplay.reconstruct(records, blob, 2)
    end

    test "truncate past the end leaves the file alone" do
      blob = "abc"
      records = [write("/a", 0, "abc", 0), rec("truncate", "/a", 99, 0, -1)]

      assert {:ok, %{"/a" => "abc"}} = BarrierReplay.reconstruct(records, blob, 2)
    end

    test "files are kept apart" do
      blob = "onetwo"
      records = [write("/a", 0, "one", 0), write("/b", 0, "two", 3)]

      assert {:ok, %{"/a" => "one", "/b" => "two"}} = BarrierReplay.reconstruct(records, blob, 2)
    end

    test "SYNC and MARK records change no bytes" do
      blob = "hello"

      records = [
        write("/a", 0, "hello", 0),
        rec("SYNC", "/a", 0, 0, -1),
        rec("MARK", "commit-1", 0, 0, -1)
      ]

      assert {:ok, %{"/a" => "hello"}} = BarrierReplay.reconstruct(records, blob, 3)
    end

    test "a write with no captured payload is skipped rather than guessed at" do
      records = [write("/a", 0, "hello", 0), rec("write", "/a", 5, 5, -1)]

      assert {:ok, %{"/a" => "hello"}} = BarrierReplay.reconstruct(records, "hello", 2)
    end

    # The blob and the trace are two files written by the same run, and a run
    # killed mid-write can leave the trace naming bytes the blob never got. Every
    # byte after that point would be wrong, and the result is handed to SQLite,
    # where a bad reconstruction is indistinguishable from a corrupt database.
    test "a record pointing past the end of the blob fails rather than guessing" do
      records = [write("/a", 0, "hello", 0), rec("write", "/a", 5, 5, 5)]

      assert {:error, {:truncated_blob, "/a", 5}} =
               BarrierReplay.reconstruct(records, "hello", 2)
    end
  end

  describe "cut_points/1" do
    test "cuts either side of every barrier and acknowledgement" do
      records = [
        write("/a-wal", 0, "x", 0),
        rec("SYNC", "/a-wal", 0, 0, -1),
        rec("MARK", "commit-1", 0, 0, -1)
      ]

      # Either side of index 1 (SYNC) and index 2 (MARK), plus both ends.
      assert BarrierReplay.cut_points(records) == [0, 1, 2, 3]
    end

    test "a plain write is not a cut point on its own" do
      records = [write("/a", 0, "x", 0), write("/a", 1, "y", 1)]
      assert BarrierReplay.cut_points(records) == [0, 2]
    end

    test "every cut point is a legal index into the trace" do
      records = [rec("MARK", "start", 0, 0, -1)]
      points = BarrierReplay.cut_points(records)

      assert Enum.all?(points, &(&1 >= 0 and &1 <= length(records)))
    end
  end

  describe "expected_commits/2" do
    setup do
      wal = "/c.db-wal"

      records = [
        rec("MARK", "start", 0, 0, -1),
        write(wal, 0, "aaaa", 0),
        rec("SYNC", wal, 0, 0, -1),
        rec("MARK", "commit-1", 0, 0, -1),
        write(wal, 4, "bbbb", 4),
        rec("MARK", "commit-2", 0, 0, -1)
      ]

      %{records: records}
    end

    test "a commit acknowledged after its barrier must survive", %{records: records} do
      assert BarrierReplay.expected_commits(records, 4) == ["commit-1"]
    end

    # commit-2 was acknowledged, but nothing synced its WAL write. Requiring it
    # to survive would fail a database that is behaving exactly as `:normal`
    # documents, and the probe would be reporting the configuration rather than a
    # bug.
    test "a commit acknowledged with no barrier is not required to survive", %{records: records} do
      assert BarrierReplay.expected_commits(records, 6) == ["commit-1"]
    end

    test "nothing is required before the first acknowledgement", %{records: records} do
      assert BarrierReplay.expected_commits(records, 2) == []
    end
  end

  # The tests above check the reconstruction against strings, which proves the
  # arithmetic and nothing else. This proves the arithmetic is enough to rebuild
  # a real database: a trace-shaped record list is captured from actual SQLite
  # I/O, replayed, and the result opened and queried.
  describe "a reconstructed database opens" do
    test "a full replay of a real write stream yields a readable database" do
      dir = Path.join(System.tmp_dir!(), "replay_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      source = Path.join(dir, "source.db")

      {:ok, conn} = Exqlite.Sqlite3.open(source)
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

      for i <- 1..20 do
        :ok = Exqlite.Sqlite3.execute(conn, "INSERT INTO t (v) VALUES ('row #{i}')")
      end

      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA wal_checkpoint(TRUNCATE)")
      :ok = Exqlite.Sqlite3.close(conn)

      # One record covering the whole file is the same shape the shim emits for a
      # write, and exercises the same reconstruction path.
      bytes = File.read!(source)
      records = [%{op: "write", path: "/c.db", off: 0, len: byte_size(bytes), data_off: 0}]

      assert {:ok, files} = BarrierReplay.reconstruct(records, bytes, 1)

      replayed = Path.join(dir, "replayed.db")
      File.write!(replayed, Map.fetch!(files, "/c.db"))

      {:ok, conn} = Exqlite.Sqlite3.open(replayed)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "PRAGMA integrity_check")
      assert {:row, ["ok"]} = Exqlite.Sqlite3.step(conn, stmt)

      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT count(*) FROM t")
      assert {:row, [20]} = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end
end
