defmodule Shroud.Shred do
  @moduledoc """
  Account deletion by destroying key material rather than data.

  ## Why this is not `DELETE FROM`

  Deleting rows is a promise about the future behaviour of a system you control. It
  says nothing about the backup taken an hour ago, the replicated WAL segment
  already in S3, or the snapshot on a disk somebody is about to decommission.
  Destroying the key that made those bytes meaningful is a claim about the bytes
  themselves, wherever they went.

  ## Three levers, and which one is the default

  **Lever 1 — `cryptoshred/1`. The default.** Delete every `Shroud.Global.KeyWrap`
  row for the user. The master key was only ever recoverable through one of those
  wraps — the server never held it — so after this it is gone for everyone,
  permanently, including the user. Every Tier 1 ciphertext in their cell becomes
  noise while the cell file stays intact, so other users' audience memberships and
  feed edges still resolve rather than dangling. A handful of row deletes in one
  transaction: instant, cheap, irreversible.

  **Lever 2 — `destroy_cell_key/1`.** Destroy the SQLCipher key. The whole file,
  its WAL, and every replicated segment become noise together, which
  `probes/ciphertext/probe.sh` verifies rather than assumes. Blunter: it also takes
  out the Tier 0 rows other users' grants point at.

  **Lever 3 — deleting the file.** Garbage collection, not a security boundary,
  which is exactly why deferring it indefinitely is safe. There is no rush and no
  window of exposure to close.

  ## What shredding cannot do

  Content keys the user wrapped to somebody else's public key never routed through
  their master key, so destroying it does not reach them. **What you shared with
  Alice, Alice keeps.** This is a property of any scheme where sharing means giving
  someone a key, and pretending otherwise would be the dishonest part. The deletion
  UI says it in plain words rather than burying it here.

  Nor does it recall metadata. Tier 0 — that this handle existed, who was in whose
  audience, when a profile was last touched — is server-visible by construction and
  survives lever 1 by design, because the feed needs it. Lever 2 reaches the cell's
  half of that; the Postgres half is ordinary data and is deleted, not shredded.
  """

  alias Shroud.Cells.Vault
  alias Shroud.Global

  require Ash.Query
  require Logger

  @doc """
  Lever 1: destroy every wrap of the user's master key.

  Returns `{:ok, count}` with the number of wraps destroyed. Marking the user
  shredded and deleting the wraps happen in one transaction — a user marked
  shredded whose wraps survived would be locked out of data that is still readable
  by whoever holds the wraps, which is the worst of both.
  """
  def cryptoshred(user_id) do
    Ash.transaction([Global.User, Global.KeyWrap], fn ->
      wraps =
        Global.KeyWrap
        |> Ash.Query.filter(user_id == ^user_id)
        |> Ash.read!()

      Enum.each(wraps, &Ash.destroy!/1)

      Global.User
      |> Ash.Query.filter(id == ^user_id)
      |> Ash.read_one!()
      |> Global.User.mark_shredded!()

      length(wraps)
    end)
    |> tap(fn
      {:ok, count} ->
        Logger.info("cryptoshredded user #{user_id}: #{count} key wraps destroyed")

      _ ->
        :ok
    end)
  end

  @doc """
  Lever 2: destroy the cell key as well.

  Only for a user who is genuinely leaving and whose Tier 0 rows nobody else needs.
  Closes the cell first, because a resident cell holds an open connection with the
  old key and would keep serving reads from it.
  """
  def destroy_cell_key(user_id) do
    with {:ok, count} <- cryptoshred(user_id) do
      :ok = Vault.destroy_key(user_id)
      Logger.info("destroyed cell key for user #{user_id}")
      {:ok, count}
    end
  end

  @doc """
  Lever 3: remove the now-meaningless file.

  Safe to defer indefinitely, and safe to run long after the fact. The bytes have
  been noise since lever 1 or 2; this only reclaims disk.
  """
  def collect_file(user_id) do
    dir = Application.get_env(:shroud, :cell_dir, "priv/cells")

    # File.rm rather than exists? followed by File.rm!: the WAL and shm files come and
    # go on their own as SQLite checkpoints, so a check-then-delete races and would
    # crash a background sweep for the most routine possible reason.
    for suffix <- ["", "-wal", "-shm"] do
      _ = File.rm(Path.join(dir, "#{user_id}.db#{suffix}"))
    end

    :ok
  end

  @doc """
  What a shred would and would not reach, for the confirmation screen.

  Built as data rather than prose in a template so the UI cannot drift from what
  the code actually does. If `cryptoshred/1` changes, this should fail to make
  sense and force an update.
  """
  def impact(user_id) do
    wraps =
      Global.KeyWrap
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.read!()

    shared_with =
      Global.AudienceMember
      |> Ash.Query.filter(owner_id == ^user_id)
      |> Ash.read!()
      |> Enum.uniq_by(& &1.member_id)
      |> length()

    %{
      wraps: Enum.map(wraps, & &1.kind),
      unreachable_after: [
        "every encrypted profile field in your cell",
        "your identity private key, so nothing new can be sealed to you"
      ],
      survives: [
        "fields you already shared — those keys were wrapped to the reader, not to you" <>
          if(shared_with > 0, do: " (#{shared_with} #{plural(shared_with)})", else: ""),
        "your handle, and the record that this account existed",
        "who was in which of your audiences, and when your profile last changed"
      ]
    }
  end

  defp plural(1), do: "reader"
  defp plural(_), do: "readers"
end
