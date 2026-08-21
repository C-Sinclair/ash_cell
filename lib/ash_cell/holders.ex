defmodule AshCell.Holders do
  @moduledoc """
  Long-lived processes that hold a tenant, as distinct from transient binds.

  `AshCell.with_tenant/2` brackets a short piece of work: it increments a counter,
  runs, and decrements. That is wrong for a LiveView, which lives for as long as a
  browser tab is open and does its work across many separate callbacks. Bracketing
  each callback would drop the count to zero between keystrokes, so a drain would
  see an idle cell and take it out from under a connected user.

  Holders are registered instead of counted, in a `Registry` with duplicate keys.
  Registry monitors its entries, so a holder that crashes, is killed, or simply has
  its tab closed is cleaned up without anything having to notice — which matters,
  because the failure mode of a leaked holder is a cell that can never be drained.

  A holder is *not* a claim on the data. Draining still takes the cell; holders
  exist so the node knows who to warn first, and so quiescence means "nobody is
  looking at this" rather than "no query is executing this millisecond".
  """

  def child_spec(_), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc """
  Registers the calling process as a holder of `tenant`.

  Idempotent per process: a LiveView that re-binds on every callback registers
  once, not once per keystroke.
  """
  def hold(cell_key) do
    if holding?(cell_key) do
      :ok
    else
      Registry.register(__MODULE__, cell_key, :held)
      :ok
    end
  end

  @doc "Releases this process's hold on `cell_key`."
  def release(cell_key) do
    Registry.unregister(__MODULE__, cell_key)
    :ok
  end

  @doc "Whether the calling process already holds `cell_key`."
  def holding?(cell_key) do
    Registry.keys(__MODULE__, self()) |> Enum.member?(cell_key)
  end

  @doc "Processes currently holding `cell_key`."
  def holders(cell_key) do
    Registry.lookup(__MODULE__, cell_key) |> Enum.map(&elem(&1, 0))
  end

  @doc "How many processes hold `cell_key`."
  def count(cell_key), do: length(holders(cell_key))

  @doc "Every cell with at least one holder, and how many."
  def fleet do
    __MODULE__
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.frequencies()
  end
end
