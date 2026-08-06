defmodule AshCell.Test.Keys do
  @moduledoc "Derived per-tenant SQLCipher keys for tests."

  def for_tenant(tenant) do
    key =
      :crypto.mac(:hmac, :sha256, "ash-cell-test-root", to_string(tenant))
      |> Base.encode16(case: :lower)

    ~s|"x'| <> key <> ~s|'"|
  end
end
