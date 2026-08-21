defmodule ShroudWeb.PeopleLive do
  @moduledoc """
  Find people, and put them in an audience.

  This page is what makes the app usable by a second person. Without a directory you
  can create an audience and then have nobody to put in it, because a handle you have
  to already know is not discovery.

  The directory is honest about a cost: it exists because handles and audience
  membership are Tier 0, so the server can enumerate them. The threat model already
  says the social graph is not private — only its contents are. An app that hid the
  graph could not offer this page at all.

  Sharing is **one-directional**, and the badges say so. Adding Bob means wrapping a
  key *for* Bob; it grants you nothing of his. That is not a missing feature to be
  papered over with a "friends" abstraction — it is what the cryptography actually does,
  and a mutual-friendship UI would misrepresent it.
  """
  use ShroudWeb, :live_view

  alias Shroud.Profiles
  alias ShroudWeb.AudienceActions

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(query: "", pending_member: nil) |> load()}
  end

  @impl true
  def handle_event("unlocked", _params, socket), do: {:noreply, socket}

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: query) |> load()}
  end

  def handle_event("add_member", %{"handle" => handle, "slug" => slug}, socket) do
    AudienceActions.request_seal(socket, handle, slug, socket.assigns.audiences)
  end

  def handle_event("member_sealed", params, socket) do
    AudienceActions.store_seal(socket, params, &load/1)
  end

  def handle_event("remove_member", %{"slug" => slug, "member-id" => member_id}, socket) do
    AudienceActions.remove(socket, slug, member_id, &load/1)
  end

  defp load(socket) do
    viewer = socket.assigns.current_user

    {micros, shared} = :timer.tc(fn -> Profiles.feed(viewer.id, limit: 50) end)

    assign(socket,
      people: Profiles.directory(viewer.id, query: socket.assigns.query),
      audiences: Profiles.audiences(viewer.id),
      shared: shared,
      cells_opened: length(shared),
      elapsed_ms: Float.round(micros / 1000, 1),
      page_title: "People"
    )
  end

  # Shaped like a post so the Timeline hook can open it: unwrapping a shared detail and
  # unwrapping a shared post are the same operation with different words.
  defp detail_json(entry, key) do
    field = Enum.find(entry.fields, &(&1.key == key))
    grant = Enum.find(entry.grants, &(&1.field_key == key))

    if field && grant do
      Jason.encode!(%{
        ciphertext: field.ciphertext,
        iv: field.iv,
        grant: %{wrapped_content_key: grant.wrapped_content_key, iv: grant.iv},
        membership: Enum.find(entry.memberships, &(&1.audience_slug == grant.audience_slug))
      })
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell current="people" user={@current_user} title="People">
      <.unlock_panel />

      <div id="directory" phx-hook="Audiences">
        <form phx-change="search" phx-submit="search" class="border-b border-zinc-200 px-4 py-3">
          <div class="flex items-center gap-2 rounded-full border border-zinc-300 px-3 py-1.5 focus-within:ring-1 focus-within:ring-zinc-400">
            <span class="hero-magnifying-glass-mini h-4 w-4 shrink-0 text-zinc-400" />
            <input
              name="query"
              value={@query}
              placeholder="Search handles"
              phx-debounce="200"
              autocomplete="off"
              class="w-full border-0 bg-transparent p-0 text-[15px] focus:ring-0"
            />
          </div>
        </form>

        <div :if={@audiences == []} class="border-b border-amber-200 bg-amber-50 px-4 py-3">
          <p class="text-[13px] text-zinc-700">
            You have no audiences yet, so there is nowhere to add anyone. Make one first —
            new accounts get a "Friends" audience automatically, so this usually means it was
            created before that existed.
          </p>
          <.link
            navigate="/settings"
            class="mt-2 inline-block rounded-full bg-zinc-900 px-3 py-1.5 text-[13px] font-semibold text-white"
          >
            Create an audience
          </.link>
        </div>

        <article
          :for={person <- @people}
          class="flex items-start gap-3 border-b border-zinc-200 px-4 py-3"
        >
          <.avatar handle={person.handle} />

          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-1.5">
              <.link
                navigate={"/u/#{person.handle}"}
                class="text-[15px] font-semibold hover:underline"
              >
                @{person.handle}
              </.link>

              <span
                :if={person.added_me_to != []}
                class="inline-flex items-center gap-1 rounded-full bg-emerald-50 px-2 py-0.5 text-[12px] font-medium text-emerald-700"
                title="They wrapped a key for you, so you can read what they share with that audience."
              >
                <span class="hero-arrow-down-left-mini h-3 w-3" /> shares with you
              </span>

              <span
                :if={person.shredded?}
                class="rounded-full bg-rose-50 px-2 py-0.5 text-[12px] font-medium text-rose-700"
              >
                deleted
              </span>
            </div>

            <p :if={person.in_my_audiences != []} class="mt-1 flex flex-wrap items-center gap-1.5">
              <span
                :for={slug <- person.in_my_audiences}
                class="inline-flex items-center gap-1 rounded-full bg-zinc-100 px-2 py-0.5 text-[12px]"
              >
                <span class="hero-lock-closed-mini h-3 w-3 text-emerald-700" />{slug}
                <button
                  phx-click="remove_member"
                  phx-value-slug={slug}
                  phx-value-member-id={person.id}
                  class="text-zinc-400 hover:text-rose-600"
                  title="Stops them receiving future posts to this audience. They keep the group key, so this is access control rather than cryptographic revocation."
                >
                  <span class="hero-x-mark-mini h-3 w-3" />
                </button>
              </span>
            </p>

            <p :if={person.in_my_audiences == []} class="mt-0.5 text-[13px] text-zinc-500">
              You share nothing with them.
            </p>
          </div>

          <form
            :if={@audiences != [] and person.can_seal?}
            phx-submit="add_member"
            class="flex shrink-0 items-center gap-1.5"
          >
            <input type="hidden" name="handle" value={person.handle} />
            <select
              name="slug"
              class="rounded-full border-zinc-300 py-1 pl-2 pr-7 text-[13px] font-medium"
            >
              <option :for={a <- @audiences} value={a.slug}>{a.name}</option>
            </select>
            <button class="rounded-full bg-zinc-900 px-3 py-1.5 text-[13px] font-semibold text-white hover:bg-zinc-700">
              Add
            </button>
          </form>

          <span
            :if={not person.can_seal?}
            class="shrink-0 text-[12px] text-zinc-400"
            title="No published public key, so there is nothing to seal a group key to."
          >
            cannot share
          </span>
        </article>

        <.empty :if={@people == []} title="Nobody found" icon="hero-users">
          <span :if={@query != ""}>No handles match "{@query}".</span>
          <span :if={@query == ""}>
            You are the only account so far. Open a second browser and register another to
            see sharing work.
          </span>
        </.empty>
      </div>

      <div :if={@shared != []}>
        <h2 class="px-4 pb-2 pt-5 text-[15px] font-bold">Details shared with you</h2>
        <p class="px-4 pb-2 text-[13px] leading-relaxed text-zinc-500">
          One SQLite file opened per person — {@cells_opened} in {@elapsed_ms} ms — to fetch
          bytes the server cannot read.
        </p>

        <div id="shared" phx-hook="Timeline">
          <article :for={entry <- @shared} class="flex gap-3 border-b border-zinc-200 px-4 py-3">
            <.avatar handle={entry.handle} />
            <div class="min-w-0 flex-1">
              <.link navigate={"/u/#{entry.handle}"} class="text-[14px] font-semibold hover:underline">
                @{entry.handle}
              </.link>
              <dl class="mt-1 grid grid-cols-[6rem_1fr] gap-x-2 text-[14px]">
                <div
                  :for={
                    {key, label} <- [
                      {"display_name", "Name"},
                      {"birthday", "Birthday"},
                      {"bio", "Bio"}
                    ]
                  }
                  class="contents"
                >
                  <dt class="text-zinc-500">{label}</dt>
                  <dd
                    data-post={detail_json(entry, key)}
                    data-body
                    data-state="pending"
                    class="data-[state=pending]:italic data-[state=pending]:text-zinc-400 data-[state=locked]:italic data-[state=locked]:text-zinc-400 data-[state=shredded]:text-rose-600"
                  >
                    {if detail_json(entry, key), do: "encrypted", else: "—"}
                  </dd>
                </div>
              </dl>
            </div>
          </article>
        </div>
      </div>

      <:aside>
        <.key_panel />
        <div class="mt-4 rounded-2xl border border-zinc-200 p-4">
          <h2 class="text-[14px] font-bold">Sharing goes one way</h2>
          <p class="mt-1 text-[12px] leading-relaxed text-zinc-500">
            Adding someone wraps a key <em>for</em> them. It grants you nothing of theirs —
            they have to add you back. There is no mutual "friendship" here because the
            cryptography does not have one.
          </p>
        </div>
      </:aside>
    </.shell>
    """
  end
end
