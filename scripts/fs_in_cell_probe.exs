# Probe: what does storing a *filesystem* in a cell cost, and what does a fork
# of one cost?
#
# The sprites-shaped question. `branch` already gives provision / snapshot /
# cut-at-a-txid / promote for free, so the only new thing is the filesystem, and
# the gating number is whether SQLite can carry one at the access pattern a real
# workload has: thousands of tiny files, a metadata lookup for every one of them,
# and a full read of the tree on every build.
#
# Three stores, same tree:
#
#   native   files on the host filesystem -- the thing being replaced
#   inline   one row per file, bytes in the row (the naive cell schema)
#   cas      inodes + content-addressed blobs (the fork-capable schema)
#
# and four operations, chosen because each one decides something:
#
#   clone    bulk write of the tree            -- can you check a repo out at all
#   stat     metadata lookup for every path    -- what FUSE does constantly
#   read     sequential read of every file     -- a build reading its sources
#   fork     produce a divergent copy          -- the product
#
# `fork` also reports bytes on disk, which is the whole argument for `cas`:
# whole-file copy is O(size) per fork and a hundred agent forks of one workspace
# is a hundred copies. Note what `cas` costs in exchange -- the blob table can be
# shared across forks, so a fork is no longer one self-contained file, which is
# the property the isolation and per-cell-encryption pitch rests on. This probe
# measures the performance half of that trade only.
#
# NOT measured, and it is the other half of the real number: FUSE. There is no
# FUSE on this machine, so every figure here is the storage layer with an
# in-process caller. A real POSIX mount adds a kernel round trip per operation on
# top of the `stat` and `read` columns, and that is where this design most
# plausibly dies. Read `stat` as a lower bound.
#
# The native baseline is APFS, not tmpfs -- macOS has no tmpfs -- so `native` is
# already paying for a real filesystem.
#
#     mix run scripts/fs_in_cell_probe.exs

defmodule FsProbe do
  @moduledoc false

  # Roughly a small node project: mostly tiny source files, a long tail of
  # bigger ones, a directory structure deep enough that path lookup is not free.
  @file_count 4_000
  @dirs 200
  @small_bytes 2_048
  @large_every 40
  @large_bytes 96 * 1024

  def run do
    dir = Path.join(System.tmp_dir!(), "ash_cell_fs_probe")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    tree = build_tree()
    total = tree |> Enum.map(fn {_, bytes} -> byte_size(bytes) end) |> Enum.sum()

    IO.puts("""

    tree: #{@file_count} files across #{@dirs} dirs, #{mb(total)} of content
    each figure is the median of 3 runs
    """)

    results =
      for store <- [FsProbe.Native, FsProbe.Inline, FsProbe.Cas] do
        {store.name(), measure(store, dir, tree)}
      end

    table(results)

    IO.puts("""

    fork is one fork of the populated tree. `bytes` is what that fork added on
    disk, which for a hundred agent forks is the number that matters, not the ms.

    caveat on native's fork bytes: `cp -Rc` asks APFS to clone, so the physical
    cost is near zero too. The figure is the logical size, and it is the only
    column here where logical and physical differ. Do not quote it as 17 MB of
    disk -- native and cas are both cheap to fork, for different reasons.
    """)

    File.rm_rf!(dir)
  end

  defp measure(store, dir, tree) do
    root = Path.join(dir, store.slug())

    clone = median(fn -> with_fresh(store, root, fn h -> time(fn -> store.clone(h, tree) end) end) end)

    populated = fn fun ->
      with_fresh(store, root, fn h ->
        store.clone(h, tree)
        fun.(h)
      end)
    end

    paths = Enum.map(tree, &elem(&1, 0))

    stat = median(fn -> populated.(fn h -> time(fn -> store.stat_all(h, paths) end) end) end)
    read = median(fn -> populated.(fn h -> time(fn -> store.read_all(h, paths) end) end) end)

    {fork_us, fork_bytes} =
      populated.(fn h ->
        target = root <> "-fork"
        rm(target)
        us = time(fn -> store.fork(h, target) end)
        bytes = du(target)
        rm(target)
        {us, bytes}
      end)

    %{clone: clone, stat: stat, read: read, fork: fork_us, fork_bytes: fork_bytes}
  end

  defp with_fresh(store, root, fun) do
    rm(root)
    handle = store.open(root)

    try do
      fun.(handle)
    after
      store.close(handle)
      rm(root)
    end
  end

  # A deterministic tree, so every store is handed byte-identical content and the
  # cas numbers are not flattered by accidental duplicate blobs.
  defp build_tree do
    for i <- 1..@file_count do
      d1 = rem(i, @dirs) |> Integer.to_string() |> String.pad_leading(3, "0")
      d2 = rem(div(i, @dirs), 8)
      path = "pkg/#{d1}/sub#{d2}/mod_#{i}.ex"

      size = if rem(i, @large_every) == 0, do: @large_bytes, else: @small_bytes
      {path, :crypto.hash(:sha256, "seed#{i}") |> pad_to(size)}
    end
  end

  defp pad_to(seed, size) do
    seed
    |> List.duplicate(div(size, byte_size(seed)) + 1)
    |> IO.iodata_to_binary()
    |> binary_part(0, size)
  end

  def time(fun) do
    {us, _} = :timer.tc(fun)
    us
  end

  defp median(fun) do
    fun.()
    1..3 |> Enum.map(fn _ -> fun.() end) |> Enum.sort() |> Enum.at(1)
  end

  defp rm(path), do: File.rm_rf!(path)

  defp du(path) do
    cond do
      File.regular?(path) ->
        File.stat!(path).size

      File.dir?(path) ->
        path
        |> Path.join("**")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&File.stat!(&1).size)
        |> Enum.sum()

      true ->
        0
    end
  end

  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp table(results) do
    cols = [{"clone", :clone}, {"stat", :stat}, {"read", :read}, {"fork", :fork}]

    IO.puts(
      String.pad_trailing("", 10) <>
        Enum.map_join(cols, "", &String.pad_leading(elem(&1, 0), 12)) <>
        String.pad_leading("fork bytes", 14)
    )

    for {name, r} <- results do
      IO.puts(
        String.pad_trailing(name, 10) <>
          Enum.map_join(cols, "", fn {_, key} -> String.pad_leading(ms(r[key]), 12) end) <>
          String.pad_leading(mb(r.fork_bytes), 14)
      )
    end
  end

  defp ms(us), do: "#{round(us / 1000)} ms"
end

defmodule FsProbe.Native do
  @moduledoc false
  def name, do: "native"
  def slug, do: "native"

  def open(root) do
    File.mkdir_p!(root)
    root
  end

  def close(_root), do: :ok

  def clone(root, tree) do
    for {path, bytes} <- tree do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, bytes)
    end
  end

  def stat_all(root, paths) do
    for path <- paths, do: File.stat!(Path.join(root, path)).size
  end

  def read_all(root, paths) do
    for path <- paths, do: byte_size(File.read!(Path.join(root, path)))
  end

  # cp -c asks APFS for a clone; without it this is a byte copy and the
  # comparison is unfair to the host filesystem rather than to SQLite.
  def fork(root, target) do
    {_, 0} = System.cmd("cp", ["-Rc", root, target], stderr_to_stdout: true)
  end
end

defmodule FsProbe.SqliteStore do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      def open(root) do
        File.mkdir_p!(Path.dirname(root))
        {:ok, conn} = Exqlite.Sqlite3.open(root)
        pragmas(conn)
        schema(conn)
        %{conn: conn, path: root}
      end

      def close(%{conn: conn}), do: Exqlite.Sqlite3.close(conn)

      defp pragmas(conn) do
        for p <- ["journal_mode = WAL", "synchronous = NORMAL", "page_size = 8192"] do
          :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA #{p}")
        end
      end

      defp exec(conn, sql), do: :ok = Exqlite.Sqlite3.execute(conn, sql)

      defp each(conn, sql, rows) do
        exec(conn, "BEGIN IMMEDIATE")
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

        for args <- rows do
          :ok = Exqlite.Sqlite3.bind(stmt, args)
          :done = Exqlite.Sqlite3.step(conn, stmt)
        end

        :ok = Exqlite.Sqlite3.release(conn, stmt)
        exec(conn, "COMMIT")
      end

      defp query(conn, sql, args) do
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
        :ok = Exqlite.Sqlite3.bind(stmt, args)
        {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
        :ok = Exqlite.Sqlite3.release(conn, stmt)
        rows
      end

      # A fork has to see a checkpointed file, or it copies a database missing
      # everything still in the WAL.
      defp checkpoint(conn), do: exec(conn, "PRAGMA wal_checkpoint(TRUNCATE)")
    end
  end
end

defmodule FsProbe.Inline do
  @moduledoc false
  use FsProbe.SqliteStore

  def name, do: "inline"
  def slug, do: "inline.db"

  defp schema(conn) do
    exec(conn, """
    CREATE TABLE IF NOT EXISTS files (
      path TEXT PRIMARY KEY,
      size INTEGER NOT NULL,
      content BLOB NOT NULL
    ) WITHOUT ROWID
    """)
  end

  def clone(%{conn: conn}, tree) do
    each(conn, "INSERT INTO files (path, size, content) VALUES (?1, ?2, ?3)", for({p, b} <- tree, do: [p, byte_size(b), b]))
  end

  def stat_all(%{conn: conn}, paths) do
    for path <- paths, do: query(conn, "SELECT size FROM files WHERE path = ?1", [path])
  end

  def read_all(%{conn: conn}, paths) do
    for path <- paths, do: query(conn, "SELECT content FROM files WHERE path = ?1", [path])
  end

  # The `branch` demo's fork: copy the whole file. O(size), no sharing.
  def fork(%{conn: conn, path: path}, target) do
    checkpoint(conn)
    File.cp!(path, target)
  end
end

defmodule FsProbe.Cas do
  @moduledoc false
  use FsProbe.SqliteStore

  def name, do: "cas"
  def slug, do: "cas.db"

  defp schema(conn) do
    exec(conn, """
    CREATE TABLE IF NOT EXISTS blobs (
      hash BLOB PRIMARY KEY,
      size INTEGER NOT NULL,
      content BLOB NOT NULL
    ) WITHOUT ROWID
    """)

    exec(conn, """
    CREATE TABLE IF NOT EXISTS entries (
      path TEXT PRIMARY KEY,
      size INTEGER NOT NULL,
      hash BLOB NOT NULL
    ) WITHOUT ROWID
    """)
  end

  def clone(%{conn: conn}, tree) do
    hashed = for {p, b} <- tree, do: {p, b, :crypto.hash(:sha256, b)}

    each(conn, "INSERT OR IGNORE INTO blobs (hash, size, content) VALUES (?1, ?2, ?3)", for({_, b, h} <- hashed, do: [h, byte_size(b), b]))
    each(conn, "INSERT INTO entries (path, size, hash) VALUES (?1, ?2, ?3)", for({p, b, h} <- hashed, do: [p, byte_size(b), h]))
  end

  # The point of splitting the tables: a stat never touches content, so the
  # pages it walks are the small ones.
  def stat_all(%{conn: conn}, paths) do
    for path <- paths, do: query(conn, "SELECT size FROM entries WHERE path = ?1", [path])
  end

  def read_all(%{conn: conn}, paths) do
    for path <- paths do
      query(conn, "SELECT b.content FROM entries e JOIN blobs b ON b.hash = e.hash WHERE e.path = ?1", [path])
    end
  end

  # A fork copies metadata and shares blobs, so the new cell carries entries
  # only. The blob table it reads through is the parent's, which is exactly the
  # property that stops a fork being one self-contained file.
  def fork(%{conn: conn}, target) do
    checkpoint(conn)
    exec(conn, "ATTACH DATABASE '#{target}' AS fork")
    exec(conn, "CREATE TABLE fork.entries (path TEXT PRIMARY KEY, size INTEGER NOT NULL, hash BLOB NOT NULL) WITHOUT ROWID")
    exec(conn, "INSERT INTO fork.entries SELECT * FROM entries")
    exec(conn, "DETACH DATABASE fork")
  end
end

FsProbe.run()
