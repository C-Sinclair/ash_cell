defmodule Shroud.Cells.Vault do
  @moduledoc """
  Per-user **cell** keys — the SQLCipher key for a user's database file.

  ## This key is not the user's master key, and that is deliberate

  It is tempting to encrypt the cell under the user's master key, so that the
  server genuinely cannot open the file at all. That breaks the application. The
  server must open a cell while its owner is offline in order to: serve a shared
  field to a reader, append to the owner's inbox, keep feed edges current, and run
  a migration. Deriving the cell key from MK would make every one of those require
  the owner to be present, which is precisely the thing the design is built to
  avoid.

  So there are two independent layers, and the honest summary is:

    * **Cell key** (here, server-held): protects data at rest. A stolen disk, a
      leaked backup, a copied file, a replicated WAL segment.
    * **Master key** (browser-held, never here): protects Tier 1 content from the
      server itself.

  Tier 0 is covered by the first and not the second. That is the price of having a
  working feed, and `docs/prd.md` states it rather than blurring it.

  ## Keys are derived, not minted

  HKDF over a root secret and the user id. A random key held in memory works until
  the node restarts, at which point every cell is encrypted under a key nobody has
  any more. In production the root secret is a KMS key; the property that matters
  is the same either way — given the root and the user id, the key is always
  recoverable.

  This module is *not* where account deletion happens. Destroying a cell key is
  the blunt shred lever (see `Shroud.Shred`); the default path destroys key wraps
  instead and leaves the file intact.
  """
  use GenServer

  @table :shroud_cell_keys

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  The SQLCipher key for a user's cell, or `nil` once the cell key is destroyed.

  Returning `nil` is what makes the blunt shred real rather than simulated: the
  cell then tries to open an encrypted database with no key and fails, exactly as
  it would if the key were genuinely gone.
  """
  def key_for(user_id) do
    if destroyed?(user_id), do: nil, else: derive(user_id)
  end

  @doc "Short, stable fingerprint for display. Never reveals the key."
  def fingerprint(user_id) do
    if destroyed?(user_id) do
      nil
    else
      :crypto.hash(:sha256, derive(user_id))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)
    end
  end

  @doc """
  Destroys a user's cell key — shred lever 2.

  The bytes on disk survive and are permanently meaningless, including every
  replicated WAL segment (`probes/ciphertext/probe.sh`). Blunter than shredding
  key wraps: it also takes out the Tier 0 rows other users' grants point at.

  Persisted, because a revocation you could undo by rebooting would not be a
  revocation.
  """
  def destroy_key(user_id) do
    AshCell.close(user_id)
    GenServer.call(__MODULE__, {:destroy, user_id})
  end

  def destroyed?(user_id) do
    case :ets.lookup(@table, {:destroyed, user_id}) do
      [{_, true}] -> true
      _ -> false
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    for user_id <- load_destroyed() do
      :ets.insert(@table, {{:destroyed, user_id}, true})
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:destroy, user_id}, _from, state) do
    :ets.insert(@table, {{:destroyed, user_id}, true})
    persist_destroyed()
    {:reply, :ok, state}
  end

  # exqlite interpolates the key straight into `PRAGMA key = <value>`, so the value
  # must arrive as a valid SQL literal, quotes included. `"x'<hex>'"` is SQLCipher's
  # raw-key form: it uses the 256 bits verbatim and skips key derivation. A bare hex
  # string fails with "unrecognized token"; an unquoted x'..' is a syntax error.
  defp derive(user_id) do
    key =
      :crypto.mac(:hmac, :sha256, root_secret(), "shroud-cell:" <> to_string(user_id))
      |> Base.encode16(case: :lower)

    ~s|"x'| <> key <> ~s|'"|
  end

  defp root_secret do
    Application.get_env(:shroud, :vault_root_secret) || "shroud-root-secret-not-for-production"
  end

  defp destroyed_path,
    do: Path.join(Application.get_env(:shroud, :cell_dir, "priv/cells"), ".destroyed")

  defp load_destroyed do
    case File.read(destroyed_path()) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      _ -> []
    end
  end

  defp persist_destroyed do
    destroyed = :ets.select(@table, [{{{:destroyed, :"$1"}, true}, [], [:"$1"]}])
    File.mkdir_p!(Path.dirname(destroyed_path()))
    File.write!(destroyed_path(), Enum.join(destroyed, "\n"))
  end
end
