defmodule Shroud.DirectoryTest do
  @moduledoc """
  Discovery and membership. The cold-start path — "I made an audience and there is
  nobody to add" — was a real dead end, so these cover finding people and the
  one-directional nature of what adding them does.
  """
  use Shroud.CellCase, async: false

  describe "directory/2" do
    test "lists everyone except the viewer" do
      %{user: me} = unique_user("me")
      %{user: other} = unique_user("other")

      handles = Profiles.directory(me.id) |> Enum.map(& &1.handle)

      assert other.handle in handles
      refute me.handle in handles
    end

    test "filters by handle, ignoring a leading @" do
      %{user: me} = unique_user("me")
      %{user: target} = unique_user("findme")
      %{user: _noise} = unique_user("other")

      assert [found] = Profiles.directory(me.id, query: "findme")
      assert found.handle == target.handle

      assert [^found] = Profiles.directory(me.id, query: "  @findme ")
    end

    test "a blank query is treated as no query rather than matching nothing" do
      %{user: me} = unique_user("me")
      %{user: _other} = unique_user("other")

      assert length(Profiles.directory(me.id, query: "   ")) == 1
    end

    test "reports which of my audiences they are in" do
      %{user: me} = unique_user("me")
      %{user: them} = unique_user("them")

      join(me, them, "friends")

      assert [person] = Profiles.directory(me.id)
      assert person.in_my_audiences == ["friends"]
      # One-directional: adding them grants me nothing of theirs.
      assert person.added_me_to == []
    end

    test "reports separately that they share with me" do
      %{user: me} = unique_user("me")
      %{user: them} = unique_user("them")

      join(them, me, "family")

      assert [person] = Profiles.directory(me.id)
      assert person.added_me_to == ["family"]
      assert person.in_my_audiences == []
    end

    test "flags a user with no public key as unshareable" do
      %{user: me} = unique_user("me")

      keyless =
        Ash.create!(
          Global.User,
          %{handle: "keyless-#{System.unique_integer([:positive])}"},
          action: :register
        )

      track(keyless.id)

      assert [person] = Profiles.directory(me.id)
      assert person.handle == keyless.handle
      # Nothing to seal a group key to, so the UI must not offer an Add button.
      refute person.can_seal?
    end

    test "flags a shredded account" do
      %{user: me} = unique_user("me")
      %{user: gone} = unique_user("gone")
      add_wrap(gone)
      {:ok, _} = Shred.cryptoshred(gone.id)

      assert [person] = Profiles.directory(me.id)
      assert person.shredded?
    end
  end

  describe "remove_member/3" do
    test "stops future posts reaching them" do
      %{user: owner} = unique_user("owner")
      %{user: member} = unique_user("member")

      join(owner, member, "friends")
      {:ok, _} = publish_private(owner.id, "friends")

      assert length(Profiles.timeline(member.id)) == 1

      :ok = Profiles.remove_member(owner.id, "friends", member.id)
      {:ok, _} = publish_private(owner.id, "friends")

      # Access control, not cryptography: they still hold the group key from when they
      # joined, but the index no longer hands them the ciphertext.
      assert Profiles.timeline(member.id) == []
    end

    test "removes the feed edge too, so a stale profile stops appearing" do
      %{user: owner} = unique_user("owner")
      %{user: member} = unique_user("member")

      join(owner, member, "friends")
      {:ok, _} = put_field(owner.id, "display_name", "Ada", "friends")
      assert length(Profiles.feed(member.id)) == 1

      :ok = Profiles.remove_member(owner.id, "friends", member.id)

      assert Profiles.feed(member.id) == []
    end

    test "leaves other audiences alone" do
      %{user: owner} = unique_user("owner")
      %{user: member} = unique_user("member")

      join(owner, member, "friends")
      join(owner, member, "family")

      :ok = Profiles.remove_member(owner.id, "friends", member.id)

      assert [person] = Profiles.directory(owner.id)
      assert person.in_my_audiences == ["family"]
    end

    test "is safe on somebody who was never a member" do
      %{user: owner} = unique_user("owner")
      %{user: stranger} = unique_user("stranger")

      assert :ok = Profiles.remove_member(owner.id, "friends", stranger.id)
    end
  end

  defp publish_private(author_id, slug) do
    Profiles.publish_post(author_id, %{
      visibility: slug,
      ciphertext: Base.encode64(:crypto.strong_rand_bytes(64)),
      iv: Base.encode64(:crypto.strong_rand_bytes(12)),
      content_key_id: "ck",
      wrapped_content_key: Base.encode64(:crypto.strong_rand_bytes(48)),
      wrap_iv: Base.encode64(:crypto.strong_rand_bytes(12)),
      own_wrapped_content_key: Base.encode64(:crypto.strong_rand_bytes(48)),
      own_wrap_iv: Base.encode64(:crypto.strong_rand_bytes(12))
    })
  end

  defp join(owner, member, slug) do
    {:ok, _} =
      Profiles.add_member(owner.id, slug, member.id, %{
        "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48)),
        "ephemeral_public_key" => Base.encode64(:crypto.strong_rand_bytes(91)),
        "iv" => Base.encode64(:crypto.strong_rand_bytes(12))
      })
  end
end
