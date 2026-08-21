defmodule Shroud.ShredTest do
  @moduledoc """
  Cryptoshredding. The claim under test is not "rows were deleted" — that is
  trivially true — but the three properties that make destroying keys a *better*
  deletion story than destroying data.
  """
  use Shroud.CellCase, async: false

  describe "lever 1: destroying key wraps" do
    test "destroys every wrap, so the master key is unrecoverable by any path" do
      %{user: user} = unique_user()
      add_wrap(user, :passphrase)
      add_wrap(user, :prf)
      add_wrap(user, :device)

      assert {:ok, 3} = Shred.cryptoshred(user.id)

      remaining = Global.KeyWrap |> Ash.Query.filter(user_id == ^user.id) |> Ash.read!()
      assert remaining == []
    end

    test "leaves the cell file intact, and the ciphertext still in it" do
      %{user: user} = unique_user()
      add_wrap(user)
      {:ok, _} = put_field(user.id, "bio", "still here", "friends")

      {:ok, _} = Shred.cryptoshred(user.id)

      # This is the distinguishing property. The data is unreadable because the key
      # is gone, not because the rows were removed -- so everything else that points
      # into this cell keeps resolving.
      fields = Profile.Field.read!(tenant: user.id)
      assert Enum.any?(fields, &(&1.key == "bio"))
    end

    test "marks the account shredded so it cannot be signed into again" do
      %{user: user} = unique_user()
      add_wrap(user)

      {:ok, _} = Shred.cryptoshred(user.id)

      reloaded = Global.User |> Ash.Query.filter(id == ^user.id) |> Ash.read_one!()
      refute is_nil(reloaded.shredded_at)
    end

    test "another user's grants over the shredded user still resolve" do
      %{user: owner} = unique_user("owner")
      %{user: viewer} = unique_user("viewer")
      add_wrap(owner)

      {:ok, _} = put_field(owner.id, "display_name", "Ada", "friends")

      {:ok, _} =
        Global.AudienceMember.create(%{
          owner_id: owner.id,
          member_id: viewer.id,
          audience_id: "friends",
          wrapped_group_key: Base.encode64(:crypto.strong_rand_bytes(48)),
          ephemeral_public_key: Base.encode64(:crypto.strong_rand_bytes(91)),
          iv: Base.encode64(:crypto.strong_rand_bytes(12))
        })

      {:ok, _} = Shred.cryptoshred(owner.id)

      # The viewer's feed must not break. They get ciphertext and a grant; what they
      # no longer get is anything that can open it, which is a rendering problem
      # rather than a crash.
      entry = Profiles.visible_profile(owner.id, viewer.id)
      assert entry.shredded?
      assert Enum.any?(entry.fields, &(&1.key == "display_name"))
      assert Enum.any?(entry.grants, &(&1.field_key == "display_name"))
    end

    test "does not touch another user's wraps" do
      %{user: doomed} = unique_user("doomed")
      %{user: bystander} = unique_user("bystander")
      add_wrap(doomed)
      add_wrap(bystander)

      {:ok, 1} = Shred.cryptoshred(doomed.id)

      survivors = Global.KeyWrap |> Ash.Query.filter(user_id == ^bystander.id) |> Ash.read!()
      assert length(survivors) == 1
    end
  end

  describe "impact/1, which drives the confirmation screen" do
    test "names the wraps that will be destroyed" do
      %{user: user} = unique_user()
      add_wrap(user, :passphrase)
      add_wrap(user, :prf)

      impact = Shred.impact(user.id)

      assert :passphrase in impact.wraps
      assert :prf in impact.wraps
    end

    test "says plainly that shared data survives, and counts the readers" do
      %{user: owner} = unique_user("owner")
      %{user: reader} = unique_user("reader")
      add_wrap(owner)

      {:ok, _} =
        Global.AudienceMember.create(%{
          owner_id: owner.id,
          member_id: reader.id,
          audience_id: "friends",
          wrapped_group_key: Base.encode64(:crypto.strong_rand_bytes(48)),
          ephemeral_public_key: Base.encode64(:crypto.strong_rand_bytes(91)),
          iv: Base.encode64(:crypto.strong_rand_bytes(12))
        })

      survives = Enum.join(Shred.impact(owner.id).survives, " ")

      assert survives =~ "already shared"
      assert survives =~ "1 reader"
    end
  end

  describe "lever 2: destroying the cell key" do
    test "makes the cell unopenable, not merely empty" do
      %{user: user} = unique_user()
      add_wrap(user)
      {:ok, _} = put_field(user.id, "bio", "gone", "friends")

      {:ok, _} = Shred.destroy_cell_key(user.id)

      # No key means the file cannot be opened at all. The distinction from lever 1
      # matters: there, reads succeed and return noise; here, there is nothing to
      # read from.
      assert catch_error(Profile.Field.read!(tenant: user.id))
    end
  end

  describe "lever 3: collecting the file" do
    test "is safe to run and safe to skip" do
      %{user: user} = unique_user()
      add_wrap(user)
      {:ok, _} = put_field(user.id, "bio", "x", "friends")
      {:ok, _} = Shred.cryptoshred(user.id)

      AshCell.close(user.id)
      assert :ok = Shred.collect_file(user.id)
      # Idempotent: garbage collection that fails when there is no garbage would make
      # a background sweep fragile for no reason.
      assert :ok = Shred.collect_file(user.id)
    end
  end
end
