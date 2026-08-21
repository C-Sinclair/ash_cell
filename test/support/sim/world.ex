defmodule AshCell.Sim.World do
  @moduledoc """
  The observable state a run's invariants are checked against.

  Deliberately not the real system: a cell here is a generation number and a set
  of acknowledged writes. SQLite stays outside the simulation, exactly as V8 does
  in celld's, and for the same reason — it is not the part whose orderings we are
  unsure about.

  ## Snapshots are cumulative, and that is load-bearing

  `AshCell.Replicator` ships the whole database file, so a snapshot at txid N holds
  everything the shipping node had locally at that moment, not just what changed.
  Modelling it as a delta would make an entire class of bug invisible: a successor
  that resumes from an older state and ships it writes *backwards*, and only a
  cumulative model can see the earlier values disappear.

  So a node carries `values` — its database — and shipping puts that whole set at a
  txid. What is recoverable is whatever the highest-txid snapshot holds.
  """

  defstruct store: nil, nodes: %{}, acked: %{}, drained: %{}, violations: []

  defmodule Node do
    @moduledoc "One simulated node's view of the world. Beliefs, not truth."
    # `held` is what this node believes. `won` is what it actually earned, as
    # recorded by a conditional write that succeeded. Keeping them apart is what
    # lets an invariant tell a fenced writer from a split brain.
    #
    # `values` is the node's local database. `shipped_txid` is the last txid it got
    # into the store, and the counter its next shipment claims from -- local on
    # purpose, because a stale counter is what makes a fenced writer collide.
    #
    # `fenced` records that a shipment was refused. The node has *learned* it no
    # longer owns the cell, which is different from having lost it: a node can be
    # displaced long before it finds out, and what it does after finding out is the
    # part a design gets to choose.
    defstruct [
      :id,
      held: %{},
      won: [],
      local_generation: %{},
      shipped_txid: %{},
      values: %{},
      fenced: %{}
    ]
  end

  def new(node_ids, store) do
    %__MODULE__{
      store: store,
      nodes: Map.new(node_ids, &{&1, %Node{id: &1}})
    }
  end

  def node(world, id), do: Map.fetch!(world.nodes, id)

  def put_node(world, node), do: %{world | nodes: Map.put(world.nodes, node.id, node)}

  @doc """
  Records that a caller was told a write succeeded.

  Tagged with the node that said so, because "who acknowledged this" is exactly the
  question when a fenced node is still answering callers.
  """
  def ack(world, id, cell, value) do
    entry = {id, value}
    %{world | acked: Map.update(world.acked, cell, [entry], &[entry | &1])}
  end

  @doc "Everything any node has acknowledged for `cell`."
  def acked_values(world, cell) do
    world.acked |> Map.get(cell, []) |> Enum.map(fn {_id, value} -> value end)
  end

  @doc "What `id` specifically acknowledged for `cell`."
  def acked_values(world, id, cell) do
    for {^id, value} <- Map.get(world.acked, cell, []), do: value
  end

  @doc "Records that `id` completed a clean drain of `cell`."
  def drained(world, id, cell) do
    %{world | drained: Map.update(world.drained, cell, [id], &[id | &1])}
  end
end
