defmodule ShroudWeb.TimelineLive do
  @moduledoc """
  Home: the timeline, and the composer.

  Every private post here is pushed to the browser as ciphertext and decrypted by the
  `Timeline` hook. Public posts arrive readable, because they were never encrypted.
  Both kinds sit in one list, marked with a lock or a globe, which is the clearest
  demonstration of the tier split the app has: same screen, same layout, materially
  different exposure, and the difference visible without reading any documentation.

  The audiences a post can go to are pushed over the socket rather than rendered into
  the DOM. They carry wrapped group keys, and while those are opaque to the server
  there is no reason to leave key material sitting in HTML attributes where a stray
  extension or a screenshot could pick it up.
  """
  use ShroudWeb, :live_view

  alias Shroud.Profiles

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> load() |> push_audiences()}
  end

  @impl true
  def handle_event("unlocked", _params, socket), do: {:noreply, push_audiences(socket)}

  def handle_event("publish", params, socket) do
    attrs =
      params
      |> Map.take(~w(visibility body ciphertext iv content_key_id
                     wrapped_content_key wrap_iv own_wrapped_content_key own_wrap_iv))
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

    case Profiles.publish_post(socket.assigns.current_user.id, attrs) do
      {:ok, _post} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user

    # :timer.tc returns {microseconds, result} -- in that order. Binding it the other
    # way round silently assigns an integer where a list belongs.
    {micros, posts} = :timer.tc(fn -> Profiles.timeline(user.id, limit: 50) end)

    authors = posts |> Enum.map(& &1.author_id) |> Enum.uniq() |> length()

    assign(socket,
      posts: posts,
      audiences: Profiles.audiences(user.id),
      suggestions:
        user.id
        |> Profiles.directory(limit: 20)
        |> Enum.filter(&(&1.in_my_audiences == [] and &1.can_seal? and not &1.shredded?))
        |> Enum.take(3),
      cells_opened: authors,
      elapsed_ms: Float.round(micros / 1000, 1),
      page_title: "Home"
    )
  end

  defp push_audiences(socket) do
    push_event(socket, "audiences", %{
      audiences:
        Enum.map(socket.assigns.audiences, fn a ->
          %{slug: a.slug, name: a.name, wrapped_group_key: a.wrapped_group_key, iv: a.iv}
        end)
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell current="home" user={@current_user} title="Home">
      <.unlock_panel />
      <.composer audiences={@audiences} />

      <div id="timeline" phx-hook="Timeline">
        <.post_card :for={post <- @posts} post={post} />

        <.empty :if={@posts == []} title="Nothing here yet" icon="hero-chat-bubble-oval-left">
          Post something public and it appears for everyone. Post to an audience and it is
          encrypted in this tab first — only the people you added can read it.
        </.empty>
      </div>

      <:aside>
        <.key_panel />

        <div class="mt-4 rounded-2xl border border-zinc-200 p-4">
          <h2 class="text-[14px] font-bold">What the server did</h2>
          <dl class="mt-2 space-y-1 text-[13px]">
            <div class="flex justify-between gap-2">
              <dt class="text-zinc-500">Cells opened</dt>
              <dd class="font-medium tabular-nums">{@cells_opened}</dd>
            </div>
            <div class="flex justify-between gap-2">
              <dt class="text-zinc-500">Assembled in</dt>
              <dd class="font-medium tabular-nums">{@elapsed_ms} ms</dd>
            </div>
            <div class="flex justify-between gap-2">
              <dt class="text-zinc-500">Posts it could read</dt>
              <dd class="font-medium tabular-nums">
                {Enum.count(@posts, & &1.public?)} / {length(@posts)}
              </dd>
            </div>
          </dl>
          <p class="mt-2 text-[12px] leading-relaxed text-zinc-500">
            One SQLite file per author, opened to fetch bytes it cannot decrypt — except
            the public ones, which it can, because they are not encrypted.
          </p>
        </div>

        <div :if={@audiences == []} class="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4">
          <h2 class="text-[14px] font-bold">No audiences yet</h2>
          <p class="mt-1 text-[13px] leading-relaxed text-zinc-700">
            You can only post publicly until you make one. New accounts get a "Friends"
            audience automatically.
          </p>
          <.link
            navigate="/settings"
            class="mt-2 inline-block rounded-full bg-zinc-900 px-3 py-1.5 text-[13px] font-semibold text-white"
          >
            Create an audience
          </.link>
        </div>

        <div :if={@suggestions != []} class="mt-4 rounded-2xl border border-zinc-200 p-4">
          <h2 class="text-[14px] font-bold">Who to add</h2>
          <ul class="mt-2 space-y-2">
            <li :for={person <- @suggestions} class="flex items-center gap-2">
              <.avatar handle={person.handle} size="9" />
              <.link
                navigate={"/u/#{person.handle}"}
                class="min-w-0 flex-1 truncate text-[14px] font-semibold hover:underline"
              >
                @{person.handle}
              </.link>
              <span
                :if={person.added_me_to != []}
                class="rounded-full bg-emerald-50 px-1.5 py-0.5 text-[11px] font-medium text-emerald-700"
              >
                shares
              </span>
            </li>
          </ul>
          <.link
            navigate="/people"
            class="mt-3 inline-block text-[13px] font-semibold text-zinc-900 hover:underline"
          >
            Find people →
          </.link>
        </div>
      </:aside>
    </.shell>
    """
  end
end
