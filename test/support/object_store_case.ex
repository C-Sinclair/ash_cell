defmodule AshCell.ObjectStoreCase do
  @moduledoc """
  Wires tests to a real S3-compatible server.

  These tests deliberately do not mock the object store. The whole design rests on
  conditional-write semantics, and a mock would only ever confirm our own
  understanding of them.

  Start one locally with:

      minio server /tmp/ashcell-minio --address :9010

  Configured via `config/config.exs`, overridable with `ASHCELL_S3_*` env vars.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @doc """
  A cell key no earlier or later run can collide with.

  `System.unique_integer/1` is unique within a VM and restarts from small numbers
  in the next one, while the bucket outlives every run. So a name built from it
  alone gets handed a previous run's lease and snapshots: conditional writes then
  fail for a reason that has nothing to do with the test, and whether a test passes
  depends on what ran before it. Wall-clock time is what makes the name unique
  across runs; the counter keeps it unique within one.
  """
  def unique_cell(prefix),
    do: "#{prefix}_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"

  def store do
    config = Application.get_env(:ash_cell, :object_store, [])

    AshCell.ObjectStore.new(
      endpoint: env("ASHCELL_S3_ENDPOINT", config[:endpoint]),
      bucket: env("ASHCELL_S3_BUCKET", config[:bucket]),
      access_key_id: env("ASHCELL_S3_ACCESS_KEY_ID", config[:access_key_id]),
      secret_access_key: env("ASHCELL_S3_SECRET_ACCESS_KEY", config[:secret_access_key])
    )
  end

  @doc "Skips the test unless the object store is reachable, rather than failing obscurely."
  def require_object_store(_context) do
    store = store()

    case AshCell.ObjectStore.list(store, "healthcheck/") do
      {:ok, _} ->
        {:ok, store: store}

      {:error, reason} ->
        raise """
        object store unreachable at #{store.endpoint} (#{inspect(reason)})

        Start MinIO and create the bucket:

            minio server /tmp/ashcell-minio --address :9010
            mc alias set ashcell http://127.0.0.1:9010 ashcell ashcellsecret
            mc mb ashcell/#{store.bucket}
        """
    end
  end

  @doc false
  def start_fleet(dir) do
    start_supervised!(
      {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: &AshCell.TestSchema.run/1}
    )
  end

  defp env(name, default), do: System.get_env(name) || default
end
