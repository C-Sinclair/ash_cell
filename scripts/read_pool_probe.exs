# Probe: does widening a cell's connection pool buy concurrent read throughput,
# and what does an in-process cache buy over that?
#
# AshCell.Cell hardcodes pool_size: 1, which serialises every read behind every
# other read on the same cell. SQLite in WAL mode is MVCC -- readers do not block
# each other and do not block the writer -- so the serialisation is an artefact of
# the pool, not of the database. This measures how much it costs.
#
#     mix run scripts/read_pool_probe.exs

defmodule PoolProbe.Repo do
  use AshSqlite.Repo, otp_app: :ash_cell
  def installed_extensions, do: []
end

defmodule PoolProbe do
  @readers 32
  @reads_per_reader 200

  def run do
    dir = Path.join(System.tmp_dir!(), "ash_cell_read_pool_probe")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "channel.db")

    seed(path)

    IO.puts("""

    #{@readers} concurrent readers x #{@reads_per_reader} pointer reads each \
    (#{@readers * @reads_per_reader} reads total)
    """)

    IO.puts("A. pointer read -- one row, primary key\n")

    for pool <- [1, 2, 4, 8, 16] do
      report("pool_size: #{pool}", fn -> measure_sqlite(path, pool, :pointer) end)
    end

    report("persistent_term", fn -> measure_persistent_term() end)

    IO.puts("""

    B. manifest resolve -- filter + join over artifacts, ~12 rows
    """)

    for pool <- [1, 2, 4, 8, 16] do
      report("pool_size: #{pool}", fn -> measure_sqlite(path, pool, :manifest) end)
    end

    File.rm_rf!(dir)
  end

  defp seed(path) do
    {:ok, pid} = start(path, 1)

    Ecto.Adapters.SQL.query!(pid, "PRAGMA journal_mode = WAL", [])

    Ecto.Adapters.SQL.query!(
      pid,
      "CREATE TABLE channels (id TEXT PRIMARY KEY, release TEXT NOT NULL)",
      []
    )

    Ecto.Adapters.SQL.query!(
      pid,
      "INSERT INTO channels (id, release) VALUES ('prod', 'release-42')",
      []
    )

    Ecto.Adapters.SQL.query!(
      pid,
      """
      CREATE TABLE artifacts (
        id TEXT PRIMARY KEY,
        release TEXT NOT NULL,
        kind TEXT NOT NULL,
        platform TEXT NOT NULL,
        arch TEXT NOT NULL,
        min_runtime INTEGER NOT NULL,
        blob_hash TEXT NOT NULL,
        size INTEGER NOT NULL
      )
      """,
      []
    )

    Ecto.Adapters.SQL.query!(pid, "CREATE INDEX artifacts_release ON artifacts (release)", [])

    # 40 releases x 24 artifacts, so the filtered read is a real index lookup
    # over a table with rows it has to reject, not a scan of exactly the answer.
    for r <- 1..40, a <- 1..24 do
      Ecto.Adapters.SQL.query!(
        pid,
        "INSERT INTO artifacts VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        [
          "artifact-#{r}-#{a}",
          "release-#{r}",
          Enum.at(~w[bundle asset map], rem(a, 3)),
          Enum.at(~w[ios android], rem(a, 2)),
          Enum.at(~w[arm64 x86_64], rem(div(a, 2), 2)),
          140 + rem(a, 5),
          :crypto.hash(:sha256, "#{r}-#{a}") |> Base.encode16(case: :lower),
          1_000 * a
        ]
      )
    end

    :persistent_term.put({:pool_probe, "prod"}, "release-42")

    Supervisor.stop(pid)
  end

  defp start(path, pool_size) do
    PoolProbe.Repo.start_link(
      name: nil,
      database: path,
      pool_size: pool_size,
      journal_mode: :wal,
      log: false,
      backoff_type: :stop
    )
  end

  # One read = resolve the pointer for a channel, which is the whole of the OTA
  # read path once the manifest is denormalised onto the row.
  @manifest_sql """
  SELECT a.blob_hash, a.kind, a.size
  FROM channels c
  JOIN artifacts a ON a.release = c.release
  WHERE c.id = ?1 AND a.platform = ?2 AND a.arch = ?3 AND a.min_runtime <= ?4
  ORDER BY a.kind, a.blob_hash
  """

  defp measure_sqlite(path, pool_size, shape) do
    {:ok, repo_pid} = start(path, pool_size)

    # Warm the pool so connection setup is not counted.
    read = reader(repo_pid, shape)
    read.()

    result =
      time(fn ->
        1..@readers
        |> Task.async_stream(
          fn _ ->
            for _ <- 1..@reads_per_reader, do: read.()
          end,
          max_concurrency: @readers,
          timeout: :infinity
        )
        |> Stream.run()
      end)

    Supervisor.stop(repo_pid)
    result
  end

  defp reader(repo_pid, :pointer) do
    fn ->
      Ecto.Adapters.SQL.query!(repo_pid, "SELECT release FROM channels WHERE id = ?1", ["prod"])
    end
  end

  defp reader(repo_pid, :manifest) do
    fn ->
      Ecto.Adapters.SQL.query!(repo_pid, @manifest_sql, ["prod", "ios", "arm64", 142])
    end
  end

  defp measure_persistent_term do
    time(fn ->
      1..@readers
      |> Task.async_stream(
        fn _ ->
          for _ <- 1..@reads_per_reader do
            :persistent_term.get({:pool_probe, "prod"})
          end
        end,
        max_concurrency: @readers,
        timeout: :infinity
      )
      |> Stream.run()
    end)
  end

  defp time(fun) do
    {micros, :ok} = :timer.tc(fun)
    micros
  end

  # Median of five, so one scheduler hiccup does not become the headline.
  defp report(label, fun) do
    fun.()

    micros =
      1..5
      |> Enum.map(fn _ -> fun.() end)
      |> Enum.sort()
      |> Enum.at(2)

    total = @readers * @reads_per_reader
    per_read = micros / total
    per_sec = total / (micros / 1_000_000)

    IO.puts(
      String.pad_trailing(label, 18) <>
        String.pad_leading("#{round(micros / 1000)} ms", 9) <>
        String.pad_leading("#{Float.round(per_read, 2)} µs/read", 18) <>
        String.pad_leading("#{round(per_sec)} reads/s", 18)
    )
  end
end

PoolProbe.run()
