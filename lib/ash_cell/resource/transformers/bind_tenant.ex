defmodule AshCell.Resource.Transformers.BindTenant do
  @moduledoc """
  Points the resource's `sqlite` section at `AshCell.Binder`, turns transactions
  on, and carries the tenant to the one callback that cannot read it off a
  changeset.

  That is the entire mechanism. Everything that used to be needed on top of it —
  a global preparation, a global change, and standing down Ash's atomic path — was
  working around the fact that the binding was being made above the data layer
  instead of inside it. See `AshCell.Resource`.

  Set `tenant_binder` yourself and this leaves it alone, so a custom binder — one
  that resolves cells differently, or refuses on a node that no longer holds the
  lease — is still a one-line override. The same goes for `write_transactions?`: set it
  to `false` and multi-step actions go back to being non-atomic, which is what
  they were before this existed.

  The global change is `AshCell.Resource.Changes.CarryTenant`, and it is added
  rather than optional: `AshSqlite.DataLayer.transaction/4` raises when a
  transaction for a tenanted resource carries no tenant, so a resource with
  transactions on and the change missing would fail on its first write.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    {:ok,
     dsl
     |> default_option(:tenant_binder, AshCell.Binder)
     |> default_option(:write_transactions?, true)
     |> carry_tenant()}
  end

  defp default_option(dsl, option, value) do
    case Transformer.get_option(dsl, [:sqlite], option) do
      nil -> Transformer.set_option(dsl, [:sqlite], option, value)
      _already_set -> dsl
    end
  end

  defp carry_tenant(dsl) do
    if carries_tenant?(dsl) do
      dsl
    else
      Transformer.add_entity(dsl, [:changes], %Ash.Resource.Change{
        change: {AshCell.Resource.Changes.CarryTenant, []},
        on: [:create, :update, :destroy],
        only_when_valid?: false,
        where: []
      })
    end
  end

  defp carries_tenant?(dsl) do
    dsl
    |> Transformer.get_entities([:changes])
    |> Enum.any?(&match?(%{change: {AshCell.Resource.Changes.CarryTenant, _}}, &1))
  end
end
