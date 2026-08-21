defmodule Shroud.CellCase do
  @moduledoc """
  Test setup for anything that touches a cell.

  Cells are real files, not sandboxed transactions, so isolation here is by naming
  and cleanup rather than rollback: each test gets tenant ids nobody else uses, and
  the files are removed afterwards. Ecto's SQL sandbox covers the Postgres side only.

  `unique_user/1` exists because a leaked cell file is a cross-test data leak that
  looks like a bug in whatever runs next. Reusing a tenant id between tests would
  mean inheriting the previous test's rows through a file that outlived it.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Shroud.CellCase
      alias Shroud.{Global, Profile, Profiles, Sealing, Shred}
      require Ash.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Shroud.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Unlinked, and an Agent rather than ETS. The cleanup callback runs in a different
    # process from the test, so anything owned by or linked to the test is already gone
    # by the time cleanup wants to read it -- ETS tables and linked Agents both.
    {:ok, tenants} = Agent.start(fn -> [] end)
    Process.put(:shroud_test_tenants, tenants)

    on_exit(fn ->
      for tenant <- Agent.get(tenants, & &1) do
        AshCell.close(tenant)
        Shroud.Shred.collect_file(tenant)
      end

      Agent.stop(tenants)
    end)

    :ok
  end

  @doc "A registered user with a published public key, plus their identity private key."
  def unique_user(handle_prefix \\ "u") do
    handle = "#{handle_prefix}-#{System.unique_integer([:positive])}"
    {public_key, private_key} = Shroud.Sealing.generate_keypair()

    user =
      Ash.create!(
        Shroud.Global.User,
        %{handle: handle, public_key: public_key},
        action: :register
      )

    track(user.id)

    %{user: user, public_key: public_key, private_key: private_key}
  end

  @doc "Registers a tenant for cleanup. Any test that opens a cell must call this."
  def track(tenant) do
    case Process.get(:shroud_test_tenants) do
      nil -> :ok
      agent -> Agent.update(agent, &[tenant | &1])
    end

    tenant
  end

  @doc """
  Adds a key wrap, so a user has something to shred.

  The bytes are random rather than a real wrap: the server cannot tell the
  difference, which is the point, and the tests here are about whether the *rows*
  are destroyed. Whether the crypto round-trips is `Shroud.SealingTest`'s job.
  """
  def add_wrap(user, kind \\ :passphrase) do
    Ash.create!(
      Shroud.Global.KeyWrap,
      %{
        kind: kind,
        wrapped_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        iv: Base.encode64(:crypto.strong_rand_bytes(12)),
        kdf_salt: Base.encode64(:crypto.strong_rand_bytes(16)),
        kdf_iterations: 600_000,
        user_id: user.id
      },
      action: :create
    )
  end

  @doc "Writes an encrypted field with a grant to one audience, as the client would."
  def put_field(owner_id, key, plaintext, audience_slug) do
    content_key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, content_key, iv, plaintext, <<>>, true)

    Shroud.Profiles.put_field(
      owner_id,
      %{
        key: key,
        ciphertext: Base.encode64(ciphertext <> tag),
        iv: Base.encode64(iv),
        content_key_id: "ck-test"
      },
      [
        %{
          field_key: key,
          audience_slug: audience_slug,
          wrapped_content_key: Base.encode64(:crypto.strong_rand_bytes(48)),
          iv: Base.encode64(:crypto.strong_rand_bytes(12))
        }
      ]
    )
  end
end
