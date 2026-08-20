defmodule AshCell.Resource.Transformers.BindTenant do
  @moduledoc """
  Points the resource's `sqlite` section at `AshCell.Binder`.

  That is the entire mechanism. Everything that used to be needed on top of it —
  a global preparation, a global change, and standing down Ash's atomic path — was
  working around the fact that the binding was being made above the data layer
  instead of inside it. See `AshCell.Resource`.

  Set `tenant_binder` yourself and this leaves it alone, so a custom binder — one
  that resolves cells differently, or refuses on a node that no longer holds the
  lease — is still a one-line override.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl) do
    case Transformer.get_option(dsl, [:sqlite], :tenant_binder) do
      nil -> {:ok, Transformer.set_option(dsl, [:sqlite], :tenant_binder, AshCell.Binder)}
      _already_set -> {:ok, dsl}
    end
  end
end
