defmodule AshCell.Sim.World do
  @moduledoc """
  The observable state a run's invariants are checked against.

  Deliberately not the real system: a cell here is a generation number and a set
  of acknowledged writes. SQLite stays outside the simulation, exactly as V8 does
  in celld's, and for the same reason — it is not the part whose orderings we are
  unsure about.
  """

  defstruct store: nil, nodes: %{}, acked: %{}, violations: []

  defmodule Node do
    @moduledoc "One simulated node's view of the world. Beliefs, not truth."
    # `held` is what this node believes. `won` is what it actually earned, as
    # recorded by a conditional write that succeeded. Keeping them apart is what
    # lets an invariant tell a fenced writer from a split brain.
    defstruct [:id, held: %{}, won: [], local_generation: %{}, local_txid: %{}, snapshotted: %{}]
  end

  def new(node_ids, store) do
    %__MODULE__{
      store: store,
      nodes: Map.new(node_ids, &{&1, %Node{id: &1}})
    }
  end

  def node(world, id), do: Map.fetch!(world.nodes, id)

  def put_node(world, node), do: %{world | nodes: Map.put(world.nodes, node.id, node)}

  @doc "Records that a caller was told a write succeeded."
  def ack(world, tenant, generation, value) do
    acked = Map.update(world.acked, tenant, [{generation, value}], &[{generation, value} | &1])
    %{world | acked: acked}
  end
end
