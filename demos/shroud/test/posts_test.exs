defmodule Shroud.PostsTest do
  @moduledoc """
  Posts and the timeline. The interesting assertions are about *visibility*: who
  receives which ciphertext, and — more importantly — who never receives it at all.
  """
  use Shroud.CellCase, async: false

  describe "publishing" do
    test "a public post stores its body in the clear, by design" do
      %{user: author} = unique_user()

      {:ok, post} = publish_public(author.id, "hello, world")

      assert post.visibility == "public"
      assert post.body == "hello, world"
      assert is_nil(post.ciphertext)
    end

    test "an audience post stores ciphertext and two wraps, and no body" do
      %{user: author} = unique_user()

      {:ok, post} = publish_private(author.id, "friends")

      assert post.visibility == "friends"
      assert is_nil(post.body)
      assert post.ciphertext
      # The reader's wrap and the author's own wrap. Without the second, an author
      # cannot read their own post back.
      assert post.wrapped_content_key
      assert post.own_wrapped_content_key
    end

    test "publishing indexes the post in Postgres so a timeline can find it" do
      %{user: author} = unique_user()
      {:ok, post} = publish_public(author.id, "indexed")

      ref = Global.PostRef |> Ash.Query.filter(post_id == ^post.id) |> Ash.read_one!()

      assert ref.author_id == author.id
      assert ref.visibility == "public"
    end

    test "the index holds no content, even for a private post" do
      %{user: author} = unique_user()
      {:ok, _post} = publish_private(author.id, "friends")

      # Asserted against the resource definition rather than a struct, so it is a
      # claim about the schema instead of a snapshot of Ash internals. All the server
      # learns from indexing a private post: who, when, which audience.
      attributes =
        Global.PostRef
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert attributes == [
               :author_id,
               :id,
               :inserted_at,
               :post_id,
               :posted_at,
               :updated_at,
               :visibility
             ]

      # And no attribute is named anything content-shaped, which is what would go
      # wrong if somebody later denormalised a preview into the index for speed.
      refute Enum.any?(attributes, &(&1 in [:body, :ciphertext, :preview, :excerpt]))
    end
  end

  describe "timeline visibility" do
    test "public posts reach a stranger who follows nobody" do
      %{user: author} = unique_user("author")
      %{user: stranger} = unique_user("stranger")

      {:ok, _} = publish_public(author.id, "anyone can read this")

      assert [post] = Profiles.timeline(stranger.id)
      assert post.public?
      assert post.body == "anyone can read this"
    end

    test "an audience post does not reach a non-member at all" do
      %{user: author} = unique_user("author")
      %{user: stranger} = unique_user("stranger")

      {:ok, _} = publish_private(author.id, "friends")

      # Not merely undecryptable -- absent. Permission is enforced at the index, so a
      # non-member cannot hoard ciphertext against a future key compromise.
      assert Profiles.timeline(stranger.id) == []
    end

    test "an audience post reaches a member, with the wrap they need" do
      %{user: author} = unique_user("author")
      %{user: member} = unique_user("member")

      {:ok, _} = publish_private(author.id, "friends")
      join(author, member, "friends")

      assert [post] = Profiles.timeline(member.id)
      refute post.public?
      assert post.ciphertext
      assert post.grant.wrapped_content_key
      assert post.membership.audience_slug == "friends"
    end

    test "being in one audience does not reveal another audience's posts" do
      %{user: author} = unique_user("author")
      %{user: member} = unique_user("member")

      {:ok, _} = publish_private(author.id, "friends")
      {:ok, _} = publish_private(author.id, "family")
      join(author, member, "friends")

      visibilities = Profiles.timeline(member.id) |> Enum.map(& &1.visibility)

      assert visibilities == ["friends"]
    end

    test "an author sees their own posts of every visibility, with their own wrap" do
      %{user: author} = unique_user("author")

      {:ok, _} = publish_public(author.id, "public one")
      {:ok, _} = publish_private(author.id, "friends")

      timeline = Profiles.timeline(author.id)

      assert length(timeline) == 2
      private = Enum.find(timeline, &(not &1.public?))
      assert private.own?
      # Their own wrap, not the audience wrap -- an author is not a member of their
      # own audience.
      assert private.own_wrap.wrapped_content_key
    end

    test "orders newest first across authors" do
      %{user: viewer} = unique_user("viewer")

      for i <- 1..3 do
        %{user: author} = unique_user("author#{i}")
        {:ok, _} = publish_public(author.id, "post #{i}")
        Process.sleep(5)
      end

      bodies = Profiles.timeline(viewer.id) |> Enum.map(& &1.body)

      assert bodies == ["post 3", "post 2", "post 1"]
    end

    test "batches by author rather than by post" do
      %{user: viewer} = unique_user("viewer")
      %{user: author} = unique_user("author")

      for i <- 1..5, do: {:ok, _} = publish_public(author.id, "p#{i}")

      # Five posts from one author is one cell, not five checkouts. Correctness proxy
      # for the batching: all five come back from a single closed-then-opened cell.
      AshCell.close(author.id)

      assert length(Profiles.timeline(viewer.id)) == 5
    end

    test "respects the limit" do
      %{user: viewer} = unique_user("viewer")
      %{user: author} = unique_user("author")

      for i <- 1..6, do: {:ok, _} = publish_public(author.id, "p#{i}")

      assert length(Profiles.timeline(viewer.id, limit: 3)) == 3
    end

    test "an empty timeline is empty" do
      %{user: viewer} = unique_user("viewer")
      assert Profiles.timeline(viewer.id) == []
    end
  end

  defp publish_public(author_id, body) do
    Profiles.publish_post(author_id, %{visibility: "public", body: body})
  end

  defp publish_private(author_id, slug) do
    Profiles.publish_post(author_id, %{
      visibility: slug,
      ciphertext: Base.encode64(:crypto.strong_rand_bytes(64)),
      iv: Base.encode64(:crypto.strong_rand_bytes(12)),
      content_key_id: "ck-test",
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
