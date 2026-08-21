defmodule Rollout.Control do
  @moduledoc """
  The write side: cut a release, promote it, ramp it, roll it back.

  Every operation here is a read-modify-write of the channel's pointer, which is
  the one thing that must not interleave. It serialises because the cell has one
  writer, and it commits atomically with its log entry because both rows are in one
  file on one connection.

  Rare, by design. A channel is written on a deploy and a rollback; it is read on
  every device check-in. Getting the pointer's consistency for free on the write
  side is affordable precisely because the write side is almost never busy.
  """

  require Ash.Query

  alias Rollout.Channel.Artifact
  alias Rollout.Channel.Pointer
  alias Rollout.Channel.Promotion
  alias Rollout.Channel.Release

  @doc """
  Creates a release and its artifacts. Does not point anything at it.

  Cutting and serving are separate on purpose: an artifact set that is half uploaded
  must never be reachable, so a release is inert until a promotion names it.
  """
  def cut(channel, version, artifacts, opts \\ []) do
    AshCell.transaction(channel, fn ->
      release =
        Release
        |> Ash.Changeset.for_create(:create, %{version: version, notes: opts[:notes]},
          tenant: channel
        )
        |> Ash.create!()

      for attrs <- artifacts do
        Artifact
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :release_id, release.id),
          tenant: channel
        )
        |> Ash.create!()
      end

      release
    end)
  end

  @doc """
  Points the channel at `release_id`, at `rollout` percent.

  The pointer move, the state changes on both releases, and the log entry are one
  transaction. A pointer that has moved without a matching log entry, or a release
  marked `:live` that nothing points at, are both states the demo should never be
  able to show — and a single-cell transaction is what makes that free rather than
  a reconciliation job.
  """
  def promote(channel, release_id, opts \\ []) do
    rollout = Keyword.get(opts, :rollout, 100)
    kind = Keyword.get(opts, :kind, :promote)

    AshCell.transaction(channel, fn ->
      previous = current_pointer(channel)

      point_at(channel, previous, release_id, rollout)

      if previous && previous.release_id && previous.release_id != release_id do
        set_state(channel, previous.release_id, superseded_state(kind))
      end

      set_state(channel, release_id, :live)

      Promotion
      |> Ash.Changeset.for_create(
        :create,
        %{
          release_id: release_id,
          from_release_id: previous && previous.release_id,
          rollout: rollout,
          kind: kind,
          reason: opts[:reason]
        },
        tenant: channel
      )
      |> Ash.create!()
    end)
  end

  @doc """
  Moves the channel back to the release it was on before the current one.

  Implemented as a promotion of the previous release rather than as a special case,
  which is the point worth making: a rollback is not a data migration and not an
  undo. It is a pointer flip, and every check-in that starts after it commits gets
  the old release.
  """
  def rollback(channel, opts \\ []) do
    case previous_release_id(channel) do
      nil ->
        {:error, :nothing_to_roll_back_to}

      release_id ->
        promote(channel, release_id,
          kind: :rollback,
          rollout: Keyword.get(opts, :rollout, 100),
          reason: Keyword.get(opts, :reason, "rolled back")
        )
    end
  end

  @doc "Changes only the rollout percentage, leaving the release alone."
  def ramp(channel, rollout) do
    case current_pointer(channel) do
      %{release_id: nil} -> {:error, :no_release}
      nil -> {:error, :no_release}
      pointer -> promote(channel, pointer.release_id, rollout: rollout, kind: :ramp)
    end
  end

  @doc """
  Blob hashes in this cell that no release references any more.

  Safe to delete from the object store, and *only* safe because the reference graph
  has exactly one writer: nobody can add a reference to a blob while this is being
  computed and acted on. With a shared database this needs a grace period, a
  two-phase mark, or a lease; here it needs a query.

  Deliberately excludes releases that are merely `:superseded` — the pointer can go
  back to those, and a rollback that finds its blobs collected is the worst possible
  outcome of a garbage collector. Only `:rolled_back` releases older than the
  retention window are collectable.
  """
  def collectable_blobs(channel, opts \\ []) do
    keep = Keyword.get(opts, :keep, 3)

    AshCell.with_tenant(channel, fn ->
      live = referenced_by_kept_releases(channel, keep)

      Artifact
      |> Ash.read!(tenant: channel)
      |> Enum.reject(&(&1.release_id in live))
      |> Enum.map(& &1.blob_hash)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in referenced_hashes(channel, live)))
    end)
  end

  defp referenced_by_kept_releases(channel, keep) do
    Release
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(tenant: channel)
    |> Enum.reject(&(&1.state == :rolled_back))
    |> Enum.take(keep)
    |> Enum.map(& &1.id)
  end

  # A blob can be shared by two releases -- an unchanged asset across a bundle
  # change is the common case -- so "unreferenced" has to mean unreferenced by
  # anything kept, not merely referenced by something dropped.
  defp referenced_hashes(channel, release_ids) do
    Artifact
    |> Ash.Query.filter(release_id in ^release_ids)
    |> Ash.read!(tenant: channel)
    |> Enum.map(& &1.blob_hash)
  end

  @doc "The channel's pointer, or nil if it has never been set."
  def current_pointer(channel) do
    Pointer
    |> Ash.Query.filter(id == ^Pointer.singleton_id())
    |> Ash.read_one!(tenant: channel)
  end

  @doc "The promotion log, newest first."
  def history(channel, limit \\ 20) do
    Promotion
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(tenant: channel)
  end

  defp previous_release_id(channel) do
    channel
    |> history(50)
    |> Enum.find_value(& &1.from_release_id)
  end

  defp point_at(channel, nil, release_id, rollout) do
    Pointer
    |> Ash.Changeset.for_create(
      :create,
      %{id: Pointer.singleton_id(), release_id: release_id, rollout: rollout},
      tenant: channel
    )
    |> Ash.create!()
  end

  defp point_at(channel, pointer, release_id, rollout) do
    pointer
    |> Ash.Changeset.for_update(:point_at, %{release_id: release_id, rollout: rollout},
      tenant: channel
    )
    |> Ash.update!()
  end

  defp set_state(channel, release_id, state) do
    Release
    |> Ash.Query.filter(id == ^release_id)
    |> Ash.read_one!(tenant: channel)
    |> case do
      nil ->
        :ok

      release ->
        release
        |> Ash.Changeset.for_update(:set_state, %{state: state}, tenant: channel)
        |> Ash.update!()
    end
  end

  # A release the pointer moved *off* is superseded; one it was rolled back from is
  # marked as such, because the two are operationally different and the garbage
  # collector treats them differently.
  defp superseded_state(:rollback), do: :rolled_back
  defp superseded_state(_kind), do: :superseded
end
