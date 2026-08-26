defmodule Relay.Cells do
  @moduledoc """
  Where a stream's cell is, and what it is called.

  **One cell per stream.** A stream is the unit of ordering and the unit of resume,
  so it is the unit of the single writer. Cutting per *user* or per *tenant* instead
  would serialise every one of their concurrent generations behind one writer, which
  for this workload is exactly the wrong trade — see
  [ADR-19](../../../../docs/decisions/ADR-19-the-cell-cut-is-a-choice.md).

  There is no global registry here. A stream *is* its cell and its id is its key;
  standing up Postgres to record a mapping from a name to itself would prove
  nothing this demo is about. `console` is where the cross-store story lives.
  """

  @stream "tokens"

  @doc "The stream name inside every cell. One per cell here; the library allows many."
  def stream, do: @stream

  @doc "The cell key for a generation id."
  def cell_key(id), do: "gen:" <> id

  def config do
    [
      repo: Relay.CellRepo,
      dir: Application.get_env(:ash_cell, :dir, "priv/cells"),
      migrator: Relay.Schema,
      store: store(),
      max_resident: 64
    ]
  end

  @doc """
  The object store, or `nil` when none is configured.

  Unlike most demos this one is close to unusable without it: with no bucket
  there are no segments, so a resume can only ever be served from the cell and
  the whole point goes missing. The app still boots, and the UI says so.
  """
  def store do
    case Application.get_env(:relay, :object_store) do
      nil ->
        nil

      config ->
        AshCell.ObjectStore.new(
          endpoint: config[:endpoint],
          bucket: config[:bucket],
          access_key_id: config[:access_key_id],
          secret_access_key: config[:secret_access_key]
        )
    end
  end
end
