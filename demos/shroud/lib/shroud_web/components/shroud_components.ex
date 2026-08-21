defmodule ShroudWeb.ShroudComponents do
  @moduledoc """
  The visual vocabulary: shell, timeline, composer, and the lock/globe distinction.

  One idea runs through all of it. **The interface has to show which tier a piece of
  data is in**, because in this app that is not a technical detail — it is the whole
  proposition, and a user who cannot tell an encrypted post from a public one has
  been misled by the UI regardless of how good the cryptography is. So every post
  carries a lock or a globe, and the globe is not a warning badge tucked away: a
  public post is plainly marked as readable by the server, because it is.

  `unlock_panel/1` is here rather than inline per page because authenticated and
  unlocked are different states — a reload keeps the first and loses the second — and
  a page that forgot to render it would show empty fields instead of asking for a key.
  """
  use Phoenix.Component

  attr :current, :string, default: ""
  attr :user, :map, required: true
  attr :title, :string, default: nil
  slot :inner_block, required: true
  slot :aside

  def shell(assigns) do
    ~H"""
    <div class="mx-auto flex min-h-full max-w-6xl">
      <!-- left rail -->
      <nav class="sticky top-0 hidden h-screen w-[68px] shrink-0 flex-col gap-1 border-r border-zinc-200 px-2 py-3 sm:flex xl:w-[240px] xl:px-3">
        <div class="mb-3 flex items-center gap-2 px-2 py-1">
          <span class="grid h-9 w-9 place-items-center rounded-full bg-zinc-900 text-white">
            <span class="hero-lock-closed-mini h-[18px] w-[18px]" />
          </span>
          <span class="hidden text-lg font-bold tracking-tight xl:block">Shroud</span>
        </div>

        <.rail_link href="/home" current={@current} key="home" icon="hero-home">Home</.rail_link>
        <.rail_link href="/profile" current={@current} key="profile" icon="hero-user">
          Profile
        </.rail_link>
        <.rail_link href="/people" current={@current} key="people" icon="hero-users">
          People
        </.rail_link>
        <.rail_link href="/settings" current={@current} key="settings" icon="hero-cog-6-tooth">
          Settings
        </.rail_link>

        <div class="mt-auto flex items-center gap-2 rounded-full px-2 py-2 xl:hover:bg-zinc-100">
          <.avatar handle={@user.handle} size="9" />
          <span class="hidden min-w-0 flex-1 xl:block">
            <span class="block truncate text-[14px] font-semibold">@{@user.handle}</span>
          </span>
        </div>
      </nav>
      
    <!-- center column -->
      <div class="min-w-0 flex-1 border-zinc-200 sm:border-r">
        <header
          :if={@title}
          class="sticky top-0 z-10 border-b border-zinc-200 bg-white/85 px-4 py-3 backdrop-blur"
        >
          <h1 class="text-[17px] font-bold tracking-tight">{@title}</h1>
        </header>
        {render_slot(@inner_block)}
      </div>
      
    <!-- right rail -->
      <aside class="sticky top-0 hidden h-screen w-[300px] shrink-0 overflow-y-auto px-5 py-4 lg:block">
        {render_slot(@aside)}
      </aside>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :current, :string, required: true
  attr :key, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp rail_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-3 rounded-full px-2 py-2.5 transition hover:bg-zinc-100 xl:px-3",
        (@current == @key && "font-bold") || "font-normal"
      ]}
    >
      <span class={[@icon, "h-6 w-6 shrink-0"]} />
      <span class="hidden text-[16px] xl:block">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  @doc """
  A monogram avatar.

  Colour is derived from the handle rather than stored, so it is stable per user
  without a round trip and without another field to keep in step. There are no
  uploaded images anywhere in this app: an avatar would need server-side thumbnailing
  to be useful, and a server that must resize an image must be able to see it.
  """
  attr :handle, :string, required: true
  attr :size, :string, default: "10", values: ~w(5 9 10 16)

  # Sizes and colours are written out as whole literal class strings rather than
  # interpolated. Tailwind generates CSS by scanning source text for class names it
  # recognises, so `"h-#{@size}"` produces a class at runtime that was never compiled
  # into the stylesheet -- the element renders with no size at all, and nothing
  # anywhere reports an error.
  @avatar_sizes %{
    "5" => "h-5 w-5 text-[10px]",
    "9" => "h-9 w-9 text-[13px]",
    "10" => "h-10 w-10 text-[15px]",
    "16" => "h-16 w-16 text-2xl"
  }

  @avatar_colours ~w(
    bg-rose-500 bg-amber-500 bg-emerald-500 bg-sky-500 bg-violet-500 bg-fuchsia-500
  )

  def avatar(assigns) do
    handle = assigns.handle || "?"

    assigns =
      assign(assigns,
        size_class: Map.fetch!(@avatar_sizes, assigns.size),
        colour: Enum.at(@avatar_colours, :erlang.phash2(handle, length(@avatar_colours))),
        initial: String.upcase(String.first(handle) || "?")
      )

    ~H"""
    <span class={[
      "grid shrink-0 place-items-center rounded-full font-semibold text-white",
      @size_class,
      @colour
    ]}>
      {@initial}
    </span>
    """
  end

  @doc """
  The lock/globe marker.

  Not decoration. A reader has to be able to tell, at a glance and without trusting
  prose, whether what they are looking at was hidden from the server or handed to it.
  """
  attr :visibility, :string, required: true
  attr :class, :string, default: ""

  def tier_badge(assigns) do
    ~H"""
    <span
      :if={@visibility == "public"}
      class={["inline-flex items-center gap-1 text-[13px] text-zinc-500", @class]}
      title="Public: stored in the clear. The server can read this — that is what public means."
    >
      <span class="hero-globe-americas-mini h-4 w-4" /> Public
    </span>
    <span
      :if={@visibility != "public"}
      class={["inline-flex items-center gap-1 text-[13px] font-medium text-emerald-700", @class]}
      title={"Encrypted for #{@visibility}. The server holds ciphertext it cannot open."}
    >
      <span class="hero-lock-closed-mini h-4 w-4" /> {@visibility}
    </span>
    """
  end

  @doc """
  One post.

  Renders a placeholder for private posts and lets the client fill it in. The server
  puts ciphertext into `data-post` and has no idea what the reader ends up seeing,
  which is worth watching happen in a network inspector at least once.
  """
  attr :post, :map, required: true

  def post_card(assigns) do
    ~H"""
    <article
      data-post={if !@post.public?, do: Jason.encode!(@post)}
      data-post-id={@post.id}
      class="flex gap-3 border-b border-zinc-200 px-4 py-3 transition hover:bg-zinc-50/70"
    >
      <.avatar handle={@post.handle} />
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-1.5 text-[14px]">
          <.link navigate={"/u/#{@post.handle}"} class="font-semibold hover:underline">
            @{@post.handle}
          </.link>
          <span class="text-zinc-400">·</span>
          <time class="text-zinc-500">{ago(@post.posted_at)}</time>
          <.tier_badge visibility={@post.visibility} class="ml-auto" />
        </div>

        <p :if={@post.public?} class="mt-0.5 whitespace-pre-wrap break-words text-[15px]">
          {@post.body}
        </p>

        <p
          :if={!@post.public?}
          data-body
          data-state="pending"
          class={[
            "mt-0.5 whitespace-pre-wrap break-words text-[15px]",
            "data-[state=pending]:italic data-[state=pending]:text-zinc-400",
            "data-[state=locked]:italic data-[state=locked]:text-zinc-400",
            "data-[state=shredded]:text-rose-600"
          ]}
        >
          encrypted — unlock to read
        </p>
      </div>
    </article>
    """
  end

  @doc """
  The composer.

  The audience selector is the whole point of the control: choosing "Public" and
  choosing "Friends" send materially different things to the server, and the helper
  line under the box says which rather than leaving the user to infer it.
  """
  attr :audiences, :list, required: true

  def composer(assigns) do
    ~H"""
    <div id="composer" phx-hook="Composer" class="border-b border-zinc-200 px-4 py-3">
      <div class="flex gap-3">
        <span class="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-zinc-100">
          <span class="hero-pencil-square h-5 w-5 text-zinc-500" />
        </span>
        <div class="min-w-0 flex-1">
          <textarea
            data-body
            rows="2"
            placeholder="What's happening?"
            class="w-full resize-none border-0 p-0 text-[17px] placeholder:text-zinc-400 focus:ring-0"
          />

          <div class="mt-2 flex items-center gap-2 border-t border-zinc-100 pt-2">
            <select
              data-visibility
              class="rounded-full border-zinc-300 py-1 pl-2 pr-7 text-[13px] font-medium text-zinc-700"
            >
              <option value="public">🌐 Public — server can read</option>
              <option :for={a <- @audiences} value={a.slug}>
                🔒 {a.name} — encrypted
              </option>
            </select>

            <span data-hint class="hidden text-[13px] text-zinc-500 sm:inline"></span>

            <button
              data-publish
              class="ml-auto rounded-full bg-zinc-900 px-4 py-1.5 text-[14px] font-semibold text-white transition hover:bg-zinc-700 disabled:opacity-40"
            >
              Post
            </button>
          </div>
          <p data-status class="mt-1 text-[13px] text-rose-600"></p>
        </div>
      </div>
    </div>
    """
  end

  @doc "Right-rail panel telling the user whether their key is loaded."
  def key_panel(assigns) do
    ~H"""
    <div id="key-panel" phx-hook="KeyPanel" class="rounded-2xl border border-zinc-200 p-4">
      <h2 class="flex items-center gap-1.5 text-[14px] font-bold">
        <span class="hero-key-mini h-4 w-4" /> Your key
      </h2>
      <p data-key-state class="mt-1 text-[13px] text-zinc-600">checking…</p>
      <p class="mt-2 text-[12px] leading-relaxed text-zinc-500">
        Derived from your passkey in this tab and never sent to the server. A page load
        loses it, which is deliberate — caching it would undo what the passkey bought.
      </p>
    </div>
    """
  end

  def unlock_panel(assigns) do
    ~H"""
    <div id="unlock" phx-hook="Unlock" class="data-[locked=false]:hidden">
      <div class="border-b border-amber-200 bg-amber-50 px-4 py-3">
        <p class="flex items-center gap-1.5 text-[14px] font-semibold">
          <span class="hero-lock-closed-mini h-4 w-4" /> Locked
        </p>
        <p class="mt-1 text-[13px] text-zinc-700">
          Unlock with your passkey to read encrypted posts and your own details.
        </p>
        <div class="mt-2 flex flex-wrap gap-2">
          <input
            name="passphrase"
            type="password"
            placeholder="passphrase (only if your passkey has no PRF)"
            class="min-w-0 flex-1 rounded-full border-zinc-300 px-3 py-1.5 text-[14px]"
          />
          <button
            data-unlock
            class="rounded-full bg-zinc-900 px-4 py-1.5 text-[14px] font-semibold text-white hover:bg-zinc-700"
          >
            Unlock
          </button>
        </div>
        <p data-status class="mt-1 text-[13px] text-rose-600"></p>
      </div>
    </div>
    """
  end

  @doc "Relative time, short form."
  def ago(nil), do: ""

  def ago(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 60 -> "#{max(seconds, 0)}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d"
      true -> Calendar.strftime(at, "%-d %b")
    end
  end

  @doc "Empty-state block, so every list has something to say when it has nothing."
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  slot :inner_block

  def empty(assigns) do
    ~H"""
    <div class="px-6 py-16 text-center">
      <span class={[@icon, "mx-auto mb-3 block h-8 w-8 text-zinc-300"]} />
      <p class="text-[15px] font-semibold text-zinc-700">{@title}</p>
      <p class="mx-auto mt-1 max-w-sm text-[13px] leading-relaxed text-zinc-500">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end
end
