defmodule Shroud.FeedTest do
  @moduledoc """
  The pull-model feed. `docs/probes.md` measures how fast it is; these tests cover
  whether it is *correct*, which the probe deliberately does not.
  """
  use Shroud.CellCase, async: false

  describe "feed/2" do
    test "returns one entry per owner the viewer can see, newest first" do
      %{user: viewer} = unique_user("viewer")

      owners =
        for i <- 1..3 do
          %{user: owner} = unique_user("owner#{i}")
          {:ok, _} = put_field(owner.id, "display_name", "Owner #{i}", "friends")
          join(owner, viewer, "friends")
          # Distinct timestamps, or "newest first" is untestable.
          Process.sleep(5)
          {:ok, _} = put_field(owner.id, "bio", "bio #{i}", "friends")
          owner
        end

      entries = Profiles.feed(viewer.id)

      assert length(entries) == 3
      assert Enum.map(entries, & &1.handle) == Enum.map(Enum.reverse(owners), & &1.handle)
    end

    test "omits owners who have not added the viewer to an audience" do
      %{user: viewer} = unique_user("viewer")
      %{user: shared} = unique_user("shared")
      %{user: private} = unique_user("private")

      {:ok, _} = put_field(shared.id, "display_name", "Visible", "friends")
      {:ok, _} = put_field(private.id, "display_name", "Hidden", "friends")
      join(shared, viewer, "friends")

      handles = Profiles.feed(viewer.id) |> Enum.map(& &1.handle)

      assert shared.handle in handles
      refute private.handle in handles
    end

    test "carries the wrapped keys the viewer needs, and nothing they cannot use" do
      %{user: owner} = unique_user("owner")
      %{user: viewer} = unique_user("viewer")

      {:ok, _} = put_field(owner.id, "display_name", "Ada", "friends")
      {:ok, _} = put_field(owner.id, "birthday", "secret", "family")
      join(owner, viewer, "friends")

      [entry] = Profiles.feed(viewer.id)

      assert Enum.map(entry.fields, & &1.key) == ["display_name"]
      assert [%{audience_slug: "friends"}] = entry.memberships
    end

    test "an empty feed is empty rather than an error" do
      %{user: loner} = unique_user("loner")
      assert Profiles.feed(loner.id) == []
    end

    test "respects the page limit" do
      %{user: viewer} = unique_user("viewer")

      for i <- 1..5 do
        %{user: owner} = unique_user("owner#{i}")
        {:ok, _} = put_field(owner.id, "display_name", "O#{i}", "friends")
        join(owner, viewer, "friends")
      end

      assert length(Profiles.feed(viewer.id, limit: 2)) == 2
    end

    test "opens N cells for N owners -- the cost the probe measures" do
      %{user: viewer} = unique_user("viewer")

      owners =
        for i <- 1..8 do
          %{user: owner} = unique_user("owner#{i}")
          {:ok, _} = put_field(owner.id, "display_name", "O#{i}", "friends")
          join(owner, viewer, "friends")
          owner
        end

      # Evict everything, so the feed has to open each cell for itself. This is the
      # cold case in probe 3, and the reason `max_resident` has to exceed a page.
      for owner <- owners, do: AshCell.close(owner.id)

      entries = Profiles.feed(viewer.id)

      assert length(entries) == 8
      assert Enum.all?(entries, &(length(&1.fields) == 1))
    end
  end

  describe "feed edges" do
    test "a write refreshes the edge for every viewer who can see the owner" do
      %{user: owner} = unique_user("owner")
      %{user: a} = unique_user("a")
      %{user: b} = unique_user("b")

      join(owner, a, "friends")
      join(owner, b, "friends")

      {:ok, field} = put_field(owner.id, "display_name", "Ada", "friends")

      for viewer <- [a, b] do
        edge =
          Shroud.Global.FeedEdge
          |> Ash.Query.filter(viewer_id == ^viewer.id and owner_id == ^owner.id)
          |> Ash.read_one!()

        assert DateTime.compare(edge.profile_updated_at, field.updated_at) == :eq
      end
    end

    test "an edge is upserted rather than duplicated across repeated writes" do
      %{user: owner} = unique_user("owner")
      %{user: viewer} = unique_user("viewer")
      join(owner, viewer, "friends")

      for i <- 1..3 do
        {:ok, _} = put_field(owner.id, "display_name", "v#{i}", "friends")
      end

      edges =
        Shroud.Global.FeedEdge
        |> Ash.Query.filter(viewer_id == ^viewer.id and owner_id == ^owner.id)
        |> Ash.read!()

      assert length(edges) == 1
    end
  end

  # Goes through Profiles.add_member rather than creating the membership row directly,
  # because add_member is also what seeds the feed edge. Bypassing it produced a feed
  # that was correctly empty for members who joined after the owner last wrote.
  defp join(owner, member, slug) do
    {:ok, _} =
      Profiles.add_member(owner.id, slug, member.id, %{
        "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48)),
        "ephemeral_public_key" => Base.encode64(:crypto.strong_rand_bytes(91)),
        "iv" => Base.encode64(:crypto.strong_rand_bytes(12))
      })
  end
end
