defmodule ShroudWeb.ProfileViewLive do
  @moduledoc """
  Somebody else's profile: their details, if they shared any with you, and their posts.

  Reuses the `Timeline` hook rather than a near-copy. Opening a post is the same
  operation whether one or fifty are on screen, and two implementations of the
  group-key handling would be two places for it to drift.

  Note what an empty page means here. If this user has shared nothing with you, the
  server is not withholding a profile it can see — it has nothing readable either.
  """
  use ShroudWeb, :live_view

  alias Shroud.Global.User
  alias Shroud.Profiles

  require Ash.Query

  @impl true
  def mount(%{"handle" => handle}, _session, socket) do
    viewer = socket.assigns.current_user
    owner = User |> Ash.Query.filter(handle == ^handle) |> Ash.read_one!()

    {:ok,
     assign(socket,
       handle: handle,
       owner: owner,
       entry: owner && Profiles.visible_profile(owner.id, viewer.id),
       posts: (owner && posts_by(viewer.id, owner.id)) || [],
       page_title: "@#{handle}"
     )}
  end

  @impl true
  def handle_event("unlocked", _params, socket), do: {:noreply, socket}

  defp posts_by(viewer_id, owner_id) do
    viewer_id
    |> Profiles.timeline(limit: 100)
    |> Enum.filter(&(&1.author_id == owner_id))
  end

  defp detail_json(entry, key) do
    field = Enum.find(entry.fields, &(&1.key == key))
    grant = Enum.find(entry.grants, &(&1.field_key == key))

    if field && grant do
      Jason.encode!(%{
        ciphertext: field.ciphertext,
        iv: field.iv,
        grant: %{wrapped_content_key: grant.wrapped_content_key, iv: grant.iv},
        membership: Enum.find(entry.memberships, &(&1.audience_slug == grant.audience_slug)),
        public?: false,
        visibility: grant.audience_slug
      })
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell current="" user={@current_user} title={"@" <> @handle}>
      <.unlock_panel />

      <div :if={is_nil(@owner)}>
        <.empty title="No such handle" icon="hero-question-mark-circle">
          Nobody here by that name.
        </.empty>
      </div>

      <div :if={@owner}>
        <div class="flex items-start gap-4 border-b border-zinc-200 px-4 py-5">
          <.avatar handle={@handle} size="16" />
          <div class="min-w-0">
            <p class="text-[19px] font-bold">@{@handle}</p>
            <p
              :if={@owner.shredded_at}
              class="mt-1 inline-flex items-center gap-1 rounded-full bg-rose-50 px-2 py-0.5 text-[12px] font-medium text-rose-700"
            >
              <span class="hero-exclamation-triangle-mini h-3.5 w-3.5" />
              account deleted — keys destroyed
            </p>
          </div>
        </div>

        <section
          :if={@entry}
          id="their-details"
          phx-hook="Timeline"
          class="border-b border-zinc-200 px-4 py-4"
        >
          <h2 class="text-[15px] font-bold">Details shared with you</h2>
          <dl class="mt-3 space-y-2">
            <div
              :for={
                {key, label} <- [{"display_name", "Name"}, {"birthday", "Birthday"}, {"bio", "Bio"}]
              }
              data-post={detail_json(@entry, key)}
              class="grid grid-cols-[6.5rem_1fr] gap-2 text-[14px]"
            >
              <dt class="text-zinc-500">{label}</dt>
              <dd
                data-body
                data-state="pending"
                class="data-[state=pending]:italic data-[state=pending]:text-zinc-400 data-[state=locked]:italic data-[state=locked]:text-zinc-400 data-[state=shredded]:text-rose-600"
              >
                {if detail_json(@entry, key), do: "encrypted", else: "—"}
              </dd>
            </div>
          </dl>
          <p class="mt-3 text-[12px] text-zinc-500">
            Visible to you through {Enum.map_join(@entry.memberships, ", ", & &1.audience_slug)}.
          </p>
        </section>

        <.empty :if={is_nil(@entry)} title="Nothing shared with you" icon="hero-lock-closed">
          @{@handle} has not put you in any audience. The server is not hiding a profile it
          can see — it holds ciphertext it cannot open either.
        </.empty>

        <h2 class="px-4 pb-2 pt-4 text-[15px] font-bold">Posts</h2>
        <div id="their-posts" phx-hook="Timeline">
          <.post_card :for={post <- @posts} post={post} />
          <.empty :if={@posts == []} title="No posts you can see" icon="hero-chat-bubble-oval-left">
            Public posts would show here, as would posts to an audience you are in.
          </.empty>
        </div>
      </div>

      <:aside>
        <.key_panel />
      </:aside>
    </.shell>
    """
  end
end
