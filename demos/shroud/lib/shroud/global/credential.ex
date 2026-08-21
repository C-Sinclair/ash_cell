defmodule Shroud.Global.Credential do
  @moduledoc """
  A WebAuthn credential, as Wax hands it over.

  This resource is about *authentication only*. It proves who is calling; it has
  nothing to do with encryption. The passkey's other job — deriving a key via the
  `prf` extension — happens entirely in the browser and produces bytes that never
  appear in a request body. If PRF output ever reaches this database, that is a bug
  and not a feature.

  `sign_count` is stored because WebAuthn expects a monotonic counter as a clone
  signal. Many platform authenticators always report zero; a non-monotonic jump
  from a non-zero counter is the case worth refusing.
  """
  use Ash.Resource,
    domain: Shroud.Global,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("credentials")
    repo(Shroud.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:credential_id, :string, allow_nil?: false, public?: true)
    attribute(:cose_key, :binary, allow_nil?: false, public?: true)
    attribute(:sign_count, :integer, default: 0, public?: true)
    attribute(:label, :string, public?: true)
    timestamps()
  end

  identities do
    identity(:unique_credential_id, [:credential_id])
  end

  relationships do
    belongs_to :user, Shroud.Global.User, allow_nil?: false
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:credential_id, :cose_key, :sign_count, :label, :user_id])
      primary?(true)
    end

    update :bump_sign_count do
      accept([:sign_count])
    end
  end

  code_interface do
    define(:create)
    define(:bump_sign_count, args: [:sign_count])
  end
end
