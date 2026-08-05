defmodule AshCell.Registry do
  @moduledoc "Maps a tenant to its resident cell process."

  def child_spec(_), do: Registry.child_spec(keys: :unique, name: __MODULE__)

  def via(tenant), do: {:via, Registry, {__MODULE__, tenant}}

  def lookup(tenant) do
    case Registry.lookup(__MODULE__, tenant) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def resident_tenants do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def count, do: Registry.count(__MODULE__)
end
