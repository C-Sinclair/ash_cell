defmodule Shroud.Profiles do
  @moduledoc """
  Reading and writing profiles across cells.

  Everything here is server-side plumbing over ciphertext. No function in this
  module can read a profile field, and none of them needs to: the server's job is
  to put the right opaque bytes in front of the right browser, along with the
  wrapped key that browser can open. Decryption happens in JavaScript.

  Every function takes the tenant explicitly and passes it. There is no ambient
  current-user, because the binding is ambient and relying on it is the documented
  way to get this wrong — it does not survive a `Task`, an `Ash.load` fan-out, or a
  job boundary.
  """

  alias Shroud.Global
  alias Shroud.Profile

  require Ash.Query

  @identity_field "__identity"

  @doc """
  Writes a field and its grants atomically inside the owner's cell.

  Atomicity matters here for a specific reason: a field written without its grants
  is invisible to the audiences it was meant for, and a grant written without its
  field points at nothing. Both are silent — no error, just data that quietly is not
  where the user expects. `AshCell.transaction/2` makes it one commit.

  The feed edge update deliberately sits *outside* that transaction. It writes to
  Postgres, and a transaction cannot span a cell and Postgres any more than it can
  span two cells. So the ordering is: commit the cell first, then update the index.
  A crash between them leaves a stale `profile_updated_at`, which shows a slightly
  wrong sort order until the next write — the cheapest failure available, and much
  better than the reverse ordering, which would advertise a field that is not there.
  """
  def put_field(owner_id, attrs, grants) do
    result =
      AshCell.transaction(owner_id, fn ->
        field = Profile.Field.put!(attrs, tenant: owner_id)

        for grant <- grants do
          Profile.Grant.put!(grant, tenant: owner_id)
        end

        field
      end)

    with {:ok, field} <- result do
      refresh_feed_edges(owner_id, field.updated_at)
      {:ok, field}
    end
  end

  @doc "Every field the owner has, including the reserved identity blob."
  def own_fields(owner_id) do
    Profile.Field.read!(tenant: owner_id)
  end

  @doc "The owner's fields, minus internal ones, for the editor."
  def editable_fields(owner_id) do
    owner_id |> own_fields() |> Enum.reject(&(&1.key == @identity_field))
  end

  def own_grants(owner_id), do: Profile.Grant.read!(tenant: owner_id)
  def audiences(owner_id), do: Profile.Audience.read!(tenant: owner_id)

  def put_audience(owner_id, attrs), do: Profile.Audience.put(attrs, tenant: owner_id)

  @doc """
  Adds a member to an audience: one wrap of the group key, sealed to the member.

  This is the cheap operation, and its cheapness is the whole reason the audience
  layer exists. Sharing a field with 500 people is not 500 wraps of that field's
  content key — it is one wrap under the group key, plus one of these per member,
  once, when they join.
  """
  def add_member(owner_id, audience_slug, member_id, sealed) do
    Global.AudienceMember.create(%{
      owner_id: owner_id,
      member_id: member_id,
      audience_id: audience_slug,
      wrapped_group_key: sealed["ciphertext"] || sealed[:ciphertext],
      ephemeral_public_key: sealed["ephemeral_public_key"] || sealed[:ephemeral_public_key],
      iv: sealed["iv"] || sealed[:iv]
    })
    |> tap(fn
      {:ok, _} ->
        Global.FeedEdge.upsert(%{
          viewer_id: member_id,
          owner_id: owner_id,
          profile_updated_at: latest_update(owner_id)
        })

      _ ->
        :ok
    end)
  end

  @doc """
  Everyone else, with the state of your relationship to them.

  Discovery has to be a server-side query, and that means the handle list is Tier 0 —
  the server knows who exists and who is in whose audience. That is already stated in
  the threat model: the social graph is not private here, only its contents are. An app
  that hid the graph could not offer a directory at all, and a directory is the
  difference between this being usable and being a demo with no second user.

  Returns, per user: which of *your* audiences they are in, and whether they have added
  *you* to one of theirs. The two are independent — sharing here is one-directional by
  construction, because a grant is you wrapping a key for them.
  """
  def directory(viewer_id, opts \\ []) do
    query = opts |> Keyword.get(:query) |> normalise_query()

    users =
      Global.User
      |> Ash.Query.filter(id != ^viewer_id)
      |> then(fn q ->
        if query, do: Ash.Query.filter(q, contains(handle, ^query)), else: q
      end)
      |> Ash.Query.sort(handle: :asc)
      |> Ash.Query.limit(Keyword.get(opts, :limit, 50))
      |> Ash.read!()

    granted_by_me =
      Global.AudienceMember
      |> Ash.Query.filter(owner_id == ^viewer_id)
      |> Ash.read!()
      |> Enum.group_by(& &1.member_id, & &1.audience_id)

    added_me =
      viewer_id
      |> Global.AudienceMember.for_member!()
      |> Enum.group_by(& &1.owner_id, & &1.audience_id)

    Enum.map(users, fn user ->
      %{
        id: user.id,
        handle: user.handle,
        shredded?: not is_nil(user.shredded_at),
        can_seal?: not is_nil(user.public_key),
        in_my_audiences: granted_by_me |> Map.get(user.id, []) |> Enum.uniq(),
        added_me_to: added_me |> Map.get(user.id, []) |> Enum.uniq()
      }
    end)
  end

  defp normalise_query(nil), do: nil

  defp normalise_query(query) do
    case String.trim(query) |> String.trim_leading("@") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Removes a member from an audience.

  Worth being precise about what this does and does not do. It deletes the membership
  row, and because timeline permission is enforced at the Postgres index, the removed
  member stops receiving ciphertext for this audience's future posts. That is **access
  control, not cryptography**: they still hold the group key from when they joined, so a
  leaked database or a malicious server could hand them a future post and they could
  open it.

  Cryptographic revocation means rotating the group key and re-encrypting everything
  under it, which this PoC does not implement. The UI says so rather than implying a
  stronger guarantee than the code delivers.
  """
  def remove_member(owner_id, audience_slug, member_id) do
    Global.AudienceMember
    |> Ash.Query.filter(
      owner_id == ^owner_id and audience_id == ^audience_slug and member_id == ^member_id
    )
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    # Their feed edge goes too, or a profile they can no longer read keeps appearing.
    Global.FeedEdge
    |> Ash.Query.filter(viewer_id == ^member_id and owner_id == ^owner_id)
    |> Ash.read!()
    |> Enum.each(&Ash.destroy!/1)

    :ok
  end

  @doc """
  The pull-model feed: page an index in Postgres, then open one cell per owner.

  This is the shape `docs/probes.md` measures, and the measurement is the reason it
  is written this way rather than defensively. Probe 3 found that a cell checkout is
  ~10% of a warm feed read while the working set fits `max_resident`, and 87% of it
  when it does not. So the risk here is not fan-out; it is a resident-cell cap
  sized below a feed page. Sizing, not architecture.

  Note the two-step. Step one has to happen in Postgres because cross-data-layer
  relationships support `load` only — there is no way to sort or page cells from a
  query. Step two is the fan-out, and it returns ciphertext plus the wrapped keys
  the viewer can open, having read nothing itself.
  """
  def feed(viewer_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    memberships = Global.AudienceMember.for_member!(viewer_id)
    by_owner = Enum.group_by(memberships, & &1.owner_id)

    page =
      Global.FeedEdge.page_for_viewer!(viewer_id, page: [limit: limit, count: false])

    entries =
      for edge <- page.results, reduce: [] do
        acc ->
          case Map.get(by_owner, edge.owner_id) do
            nil -> acc
            mships -> [read_visible(edge.owner_id, mships) | acc]
          end
      end

    Enum.reverse(entries)
  end

  @doc """
  Publishes a post, and indexes it in Postgres so a timeline can find it.

  The two writes cannot be one transaction — a cell and Postgres cannot be spanned,
  the same constraint that forbids spanning two cells — so the cell commits first and
  the index follows. A crash between them leaves a post that exists but is not in
  anyone's timeline: invisible, rather than a dangling reference to nothing. That is
  the right way round, and the reverse would advertise a post that could not be read.
  """
  def publish_post(author_id, attrs) do
    with {:ok, post} <- Profile.Post.publish(attrs, tenant: author_id) do
      Global.PostRef.create(%{
        post_id: post.id,
        visibility: post.visibility,
        posted_at: post.posted_at,
        author_id: author_id
      })

      {:ok, post}
    end
  end

  @doc """
  The timeline: public posts from anyone, audience posts from people who added the
  viewer, and the viewer's own posts.

  Two steps, for the same reason the profile feed has two. Postgres decides *which*
  posts are visible and in what order — it can, because `PostRef` is Tier 0 — and
  only then are the authors' cells opened, one per author rather than one per post.
  Batching by author is what keeps a fifty-post timeline from being fifty checkouts
  when ten people wrote it.

  Permission is enforced here, at the index, not in the browser. A viewer never
  receives ciphertext for an audience they are not in, so a stored-and-waiting
  ciphertext cannot become readable later if a key leaks.
  """
  def timeline(viewer_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    memberships = Global.AudienceMember.for_member!(viewer_id)

    slugs_by_author =
      memberships
      |> Enum.group_by(& &1.owner_id, & &1.audience_id)
      |> Map.new(fn {author, slugs} -> {author, Enum.uniq(slugs)} end)

    pairs =
      Enum.map(slugs_by_author, fn {author_id, slugs} ->
        %{author_id: author_id, slugs: slugs}
      end)

    refs =
      (Global.PostRef.public_timeline!() ++
         audience_refs(pairs) ++
         Global.PostRef.for_author!(viewer_id))
      |> Enum.uniq_by(& &1.post_id)
      |> Enum.sort_by(& &1.posted_at, {:desc, DateTime})
      |> Enum.take(limit)

    membership_by_key =
      Map.new(memberships, fn m -> {{m.owner_id, m.audience_id}, m} end)

    handles = handles_for(Enum.map(refs, & &1.author_id))

    refs
    |> Enum.group_by(& &1.author_id)
    |> Enum.flat_map(fn {author_id, author_refs} ->
      ids = Enum.map(author_refs, & &1.post_id)

      ids
      |> Profile.Post.by_ids!(tenant: author_id)
      |> Enum.map(fn post ->
        post_json(post, author_id, handles[author_id], viewer_id, membership_by_key)
      end)
    end)
    |> Enum.sort_by(& &1.posted_at, {:desc, DateTime})
  end

  defp audience_refs([]), do: []
  defp audience_refs(pairs), do: Global.PostRef.for_memberships!(pairs)

  defp handles_for([]), do: %{}

  defp handles_for(ids) do
    unique = Enum.uniq(ids)

    Global.User
    |> Ash.Query.filter(id in ^unique)
    |> Ash.read!()
    |> Map.new(&{&1.id, &1.handle})
  end

  # Everything a browser needs to render one post, and nothing it cannot use. A public
  # post carries its body in the clear; a private one carries ciphertext plus exactly
  # one wrapped key -- the author's own wrap if they are reading their own post, or the
  # audience wrap plus the sealed group key if they are a member.
  defp post_json(post, author_id, handle, viewer_id, membership_by_key) do
    own? = author_id == viewer_id

    base = %{
      id: post.id,
      author_id: author_id,
      handle: handle,
      visibility: post.visibility,
      posted_at: post.posted_at,
      own?: own?,
      public?: post.visibility == "public"
    }

    cond do
      post.visibility == "public" ->
        Map.put(base, :body, post.body)

      own? ->
        Map.merge(base, %{
          ciphertext: post.ciphertext,
          iv: post.iv,
          own_wrap: %{
            wrapped_content_key: post.own_wrapped_content_key,
            iv: post.own_wrap_iv
          }
        })

      true ->
        membership = Map.get(membership_by_key, {author_id, post.visibility})

        Map.merge(base, %{
          ciphertext: post.ciphertext,
          iv: post.iv,
          grant: %{
            wrapped_content_key: post.wrapped_content_key,
            iv: post.wrap_iv
          },
          membership: membership && membership_json(membership)
        })
    end
  end

  @doc """
  What `viewer` may see of `owner`, as ciphertext plus wrapped content keys.

  The owner does not have to be online, and nothing here consults their session or
  their master key. Their grants were computed at share time and have been sitting
  in their cell ever since — that pre-computation is the entire answer to "how does
  an offline user's data get read".
  """
  def visible_profile(owner_id, viewer_id) do
    case Global.AudienceMember.for_member!(viewer_id) do
      [] ->
        nil

      memberships ->
        case Enum.filter(memberships, &(&1.owner_id == owner_id)) do
          [] -> nil
          mine -> read_visible(owner_id, mine)
        end
    end
  end

  defp read_visible(owner_id, memberships) do
    slugs = Enum.map(memberships, & &1.audience_id)

    grants = Profile.Grant.for_audiences!(slugs, tenant: owner_id)
    wanted = MapSet.new(grants, & &1.field_key)

    fields =
      owner_id
      |> own_fields()
      |> Enum.filter(&MapSet.member?(wanted, &1.key))

    owner =
      Global.User
      |> Ash.Query.filter(id == ^owner_id)
      |> Ash.read_one!()

    %{
      owner_id: owner_id,
      handle: owner && owner.handle,
      shredded?: owner && owner.shredded_at != nil,
      fields: Enum.map(fields, &field_json/1),
      grants: Enum.map(grants, &grant_json/1),
      memberships: Enum.map(memberships, &membership_json/1)
    }
  end

  defp field_json(f) do
    %{key: f.key, ciphertext: f.ciphertext, iv: f.iv, updated_at: f.updated_at}
  end

  defp grant_json(g) do
    %{
      field_key: g.field_key,
      audience_slug: g.audience_slug,
      wrapped_content_key: g.wrapped_content_key,
      iv: g.iv
    }
  end

  defp membership_json(m) do
    %{
      audience_slug: m.audience_id,
      wrapped_group_key: m.wrapped_group_key,
      ephemeral_public_key: m.ephemeral_public_key,
      iv: m.iv
    }
  end

  # Denormalising the owner's newest update out to every viewer who can see them.
  # O(viewers) per write, which is the cost of having a sortable feed at all: the
  # alternative is opening every cell just to decide what order to open them in.
  defp refresh_feed_edges(owner_id, updated_at) do
    Global.AudienceMember
    |> Ash.Query.filter(owner_id == ^owner_id)
    |> Ash.read!()
    |> Enum.uniq_by(& &1.member_id)
    |> Enum.each(fn m ->
      Global.FeedEdge.upsert(%{
        viewer_id: m.member_id,
        owner_id: owner_id,
        profile_updated_at: updated_at
      })
    end)
  end

  defp latest_update(owner_id) do
    owner_id
    |> own_fields()
    |> Enum.map(& &1.updated_at)
    |> case do
      [] -> DateTime.utc_now()
      stamps -> Enum.max(stamps, DateTime)
    end
  end
end
