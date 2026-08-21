defmodule Shroud.ZeroKnowledgeTest do
  @moduledoc """
  The claims the app is *for*. Each test here corresponds to a line in
  `docs/design.md` that would otherwise be an assertion nobody checked.
  """
  use Shroud.CellCase, async: false

  @canary "CANARY_BIRTHDAY_1987_03_02"

  describe "Tier 1 opacity" do
    test "the plaintext never reaches the cell file, even after a checkpoint" do
      %{user: user} = unique_user()

      # Written the way the client writes: encrypted before it is handed over.
      {:ok, _} = put_field(user.id, "birthday", @canary, "family")

      # Close the cell so the WAL is checkpointed into the main file, which is where a
      # naive test would look and find nothing merely because it had not been flushed.
      AshCell.close(user.id)

      path = Path.join(Application.get_env(:shroud, :cell_dir), "#{user.id}.db")
      assert File.exists?(path)
      contents = File.read!(path)

      refute String.contains?(contents, @canary)

      # And the control that makes the above mean something: the same bytes written
      # unencrypted *would* be findable. Without this, "not found" could just mean the
      # file was empty or the path was wrong.
      refute contents == ""
      assert byte_size(contents) > 1024
    end

    test "the server-side row holds ciphertext, not plaintext" do
      %{user: user} = unique_user()
      {:ok, _} = put_field(user.id, "birthday", @canary, "family")

      [field] =
        Profile.Field.read!(tenant: user.id)
        |> Enum.filter(&(&1.key == "birthday"))

      refute field.ciphertext =~ "CANARY"
      refute Base.decode64!(field.ciphertext) =~ "CANARY"

      # The key, by contrast, is deliberately plaintext -- Tier 0. The server needs it
      # to know which slot a row fills without being able to read the row.
      assert field.key == "birthday"
    end

    test "nothing in the global database can open a field" do
      %{user: user} = unique_user()
      add_wrap(user, :passphrase)
      add_wrap(user, :prf)
      {:ok, _} = put_field(user.id, "birthday", @canary, "family")

      # Every wrap the server holds, concatenated. None of it is a key; all of it is
      # sealed under something the server does not have.
      everything =
        Global.KeyWrap
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read!()
        |> Enum.map_join(" ", &"#{&1.wrapped_key} #{&1.iv} #{&1.kdf_salt}")

      refute everything =~ "CANARY"
    end
  end

  describe "reading an offline owner" do
    test "a viewer gets ciphertext and grants with the owner's cell closed and nobody bound" do
      %{user: owner} = unique_user("owner")
      %{user: viewer} = unique_user("viewer")

      {:ok, _} = put_field(owner.id, "display_name", "Ada Lovelace", "friends")
      join(owner, viewer, "friends")

      # The owner is as offline as it is possible to be: cell evicted, no binding
      # anywhere, no session, and their master key does not exist on this machine.
      AshCell.close(owner.id)
      AshCell.unbind()

      entry = Profiles.visible_profile(owner.id, viewer.id)

      assert entry.handle == owner.handle
      assert [field] = Enum.filter(entry.fields, &(&1.key == "display_name"))
      assert [grant] = Enum.filter(entry.grants, &(&1.field_key == "display_name"))

      # What the viewer needs to decrypt, all pre-computed at share time.
      assert grant.audience_slug == "friends"
      assert is_binary(grant.wrapped_content_key)
      assert is_binary(field.ciphertext)
      assert [%{audience_slug: "friends"}] = entry.memberships
    end

    test "a non-member sees nothing at all, not an empty profile" do
      %{user: owner} = unique_user("owner")
      %{user: stranger} = unique_user("stranger")

      {:ok, _} = put_field(owner.id, "display_name", "Ada", "friends")

      assert Profiles.visible_profile(owner.id, stranger.id) == nil
    end

    test "a member of one audience does not receive grants for another" do
      %{user: owner} = unique_user("owner")
      %{user: viewer} = unique_user("viewer")

      {:ok, _} = put_field(owner.id, "display_name", "Ada", "friends")
      {:ok, _} = put_field(owner.id, "birthday", @canary, "family")
      join(owner, viewer, "friends")

      entry = Profiles.visible_profile(owner.id, viewer.id)

      keys = Enum.map(entry.fields, & &1.key)
      assert "display_name" in keys

      # The birthday is not merely undecryptable to them -- its ciphertext is never
      # sent. Filtering at the query rather than in the browser means a viewer cannot
      # hoard ciphertext against a future key compromise.
      refute "birthday" in keys
    end
  end

  describe "cell isolation" do
    test "one user's field is invisible from another user's cell" do
      %{user: a} = unique_user("a")
      %{user: b} = unique_user("b")

      {:ok, _} = put_field(a.id, "bio", "a's bio", "friends")

      # Not "filtered out" -- there is no shared table for a missing WHERE clause to
      # leak across. b's database simply has no such row.
      assert Profile.Field.read!(tenant: b.id) == []
      assert length(Profile.Field.read!(tenant: a.id)) == 1
    end

    test "the global database is immune to a cell binding" do
      %{user: a} = unique_user("a")

      # The documented hazard: Ecto's dynamic binding is per repo *module*, so a
      # global resource sharing the cells' repo would write into whichever tenant
      # happened to be bound. Shroud.Repo is a different module, so it does not.
      AshCell.with_tenant(a.id, fn ->
        %{user: b} = unique_user("b")
        assert Global.User |> Ash.Query.filter(id == ^b.id) |> Ash.read_one!()
      end)
    end

    test "a transaction cannot span two cells" do
      %{user: a} = unique_user("a")
      %{user: b} = unique_user("b")

      assert_raise ArgumentError, ~r/cannot open a transaction on cell/, fn ->
        AshCell.transaction(a.id, fn ->
          AshCell.transaction(b.id, fn -> :never end)
        end)
      end
    end
  end

  defp join(owner, member, slug) do
    {:ok, _} =
      Global.AudienceMember.create(%{
        owner_id: owner.id,
        member_id: member.id,
        audience_id: slug,
        wrapped_group_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        ephemeral_public_key: Base.encode64(:crypto.strong_rand_bytes(91)),
        iv: Base.encode64(:crypto.strong_rand_bytes(12))
      })
  end
end
