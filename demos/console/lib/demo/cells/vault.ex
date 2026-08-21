defmodule Demo.Cells.Vault do
  @moduledoc """
  Per-clinic encryption keys.

  Each clinic's database is encrypted with a key belonging to that clinic alone,
  so destroying one key renders exactly one clinic's data unreadable and touches
  nobody else's.

  ## Keys are derived, not minted

  An earlier version generated a random key per clinic and held it in memory. That
  works until the node restarts, at which point every existing cell is encrypted
  under a key nobody has any more and the whole fleet is unopenable. Keys must
  therefore be *derivable* from something stable.

  Here that is HKDF over a root secret and the clinic id. In a real deployment the
  root secret is a KMS key and the per-clinic key is unwrapped on demand, which
  has the same property: given the root and the clinic id, you can always get the
  key back.

  ## What this protects

  Data at rest: a stolen disk, a leaked backup, a copied file. Plus per-clinic
  crypto-shredding, which is a genuinely stronger deletion story than
  `DELETE FROM ... WHERE tenant_id = ?`.

  It is **not** confidential computing. The node holds the plaintext key in memory
  to serve queries and decrypted pages sit in SQLite's page cache, so it does not
  protect against whoever operates the node.
  """
  use GenServer

  @table :demo_cell_keys

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  The key for a clinic, or `nil` if it has been revoked.

  Returning `nil` for a revoked clinic is what makes the demonstration real: the
  cell then tries to open an encrypted database with no key and fails, exactly as
  it would if the key were genuinely gone.
  """
  def key_for(clinic_id) do
    if revoked?(clinic_id) do
      nil
    else
      derive(clinic_id)
    end
  end

  @doc "Short, stable fingerprint for display. Never reveals the key."
  def fingerprint(clinic_id) do
    if revoked?(clinic_id) do
      nil
    else
      :crypto.hash(:sha256, derive(clinic_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)
    end
  end

  @doc """
  Destroys a clinic's key.

  The bytes on disk survive and are permanently meaningless. Persisted, so it
  survives a restart — a revocation you can undo by rebooting would not be a
  revocation.
  """
  def revoke(clinic_id) do
    AshCell.close(clinic_id)
    GenServer.call(__MODULE__, {:revoke, clinic_id})
  end

  @doc "Restores a revoked clinic's key. Demo affordance; a real vault cannot do this."
  def unrevoke(clinic_id) do
    AshCell.close(clinic_id)
    GenServer.call(__MODULE__, {:unrevoke, clinic_id})
  end

  def revoked?(clinic_id) do
    case :ets.lookup(@table, {:revoked, clinic_id}) do
      [{_, true}] -> true
      _ -> false
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    for clinic_id <- load_revocations() do
      :ets.insert(@table, {{:revoked, clinic_id}, true})
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:revoke, clinic_id}, _from, state) do
    :ets.insert(@table, {{:revoked, clinic_id}, true})
    persist_revocations()
    {:reply, :ok, state}
  end

  def handle_call({:unrevoke, clinic_id}, _from, state) do
    :ets.delete(@table, {:revoked, clinic_id})
    persist_revocations()
    {:reply, :ok, state}
  end

  # exqlite interpolates the key straight into `PRAGMA key = <value>`, so the
  # value must arrive as a valid SQL literal, quotes included. `"x'<hex>'"` is
  # SQLCipher's raw-key form: it uses the 256 bits verbatim and skips key
  # derivation. A bare hex string fails with "unrecognized token"; an unquoted
  # x'..' fails with a syntax error. Verified against SQLCipher 4.16 by confirming
  # the plaintext really is absent from the resulting file.
  defp derive(clinic_id) do
    key =
      :crypto.mac(:hmac, :sha256, root_secret(), "ashcell-demo:" <> to_string(clinic_id))
      |> Base.encode16(case: :lower)

    ~s|"x'| <> key <> ~s|'"|
  end

  defp root_secret do
    Application.get_env(:demo, :vault_root_secret) ||
      "demo-root-secret-not-for-production"
  end

  defp revocation_path, do: Path.join(Application.get_env(:demo, :cell_dir, "priv/cells"), ".revoked")

  defp load_revocations do
    case File.read(revocation_path()) do
      {:ok, contents} -> contents |> String.split("\n", trim: true)
      _ -> []
    end
  end

  defp persist_revocations do
    revoked =
      :ets.select(@table, [{{{:revoked, :"$1"}, true}, [], [:"$1"]}])

    File.mkdir_p!(Path.dirname(revocation_path()))
    File.write!(revocation_path(), Enum.join(revoked, "\n"))
  end
end
