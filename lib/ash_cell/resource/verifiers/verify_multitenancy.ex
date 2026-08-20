defmodule AshCell.Resource.Verifiers.VerifyMultitenancy do
  @moduledoc """
  Refuses a resource that cannot be tenanted, at compile time.

  Without `strategy :context` Ash never populates a tenant, so the hooks this
  extension installs would find nothing to bind and every action would quietly run
  against the default repo. A resource that shares one database is a legitimate
  thing to have — it just should not claim to be a cell.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    case Verifier.get_option(dsl, [:multitenancy], :strategy) do
      :context ->
        :ok

      other ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl, :module),
           path: [:multitenancy, :strategy],
           message: """
           AshCell.Resource requires `strategy :context`, got #{inspect(other)}.

           A cell is one database per tenant, and the tenant is how AshCell finds
           which database to open. Under any other strategy Ash leaves the tenant
           unset and every action would run against the default repo.

               multitenancy do
                 strategy :context
               end
           """
         )}
    end
  end
end
