defmodule ShroudWeb.SignInLive do
  @moduledoc """
  Registration and login.

  Both ceremonies run in JavaScript against the `/auth` endpoints, so this LiveView
  is only the form and the status line. That split is deliberate: the browser is
  where the master key is generated and where it stays, so the interesting half of
  signup is code this module cannot see and should not try to orchestrate.

  The recovery passphrase is mandatory at registration rather than optional. A user
  whose only unlock path is one authenticator loses everything when that
  authenticator is lost — and unlike an ordinary password reset there is no server
  copy to fall back on. Making it a choice would mean offering people an
  irreversible mistake in a checkbox.
  """
  use ShroudWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_user do
      {:ok, push_navigate(socket, to: "/home")}
    else
      {:ok, assign(socket, mode: :login)}
    end
  end

  @impl true
  def handle_event("mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, mode: String.to_existing_atom(mode))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto grid min-h-full max-w-5xl items-center gap-10 px-6 py-12 lg:grid-cols-2 lg:gap-16">
      <div>
        <span class="grid h-12 w-12 place-items-center rounded-full bg-zinc-900 text-white">
          <span class="hero-lock-closed h-6 w-6" />
        </span>
        <h1 class="mt-6 text-4xl font-bold tracking-tight sm:text-5xl">
          Your data, stored here.<br />
          <span class="text-zinc-400">Readable only there.</span>
        </h1>
        <p class="mt-4 max-w-md text-[15px] leading-relaxed text-zinc-600">
          A profile and posts app on one encrypted SQLite database per person. Your key comes
          from your passkey, inside your browser, and is never sent to this server.
        </p>

        <dl class="mt-8 space-y-4">
          <div class="flex gap-3">
            <span class="hero-lock-closed-mini mt-0.5 h-4 w-4 shrink-0 text-emerald-700" />
            <div>
              <dt class="text-[14px] font-semibold">Posts to an audience are encrypted</dt>
              <dd class="text-[13px] leading-relaxed text-zinc-600">
                Sealed in your browser. We store bytes we cannot open.
              </dd>
            </div>
          </div>
          <div class="flex gap-3">
            <span class="hero-globe-americas-mini mt-0.5 h-4 w-4 shrink-0 text-zinc-500" />
            <div>
              <dt class="text-[14px] font-semibold">Public posts are not</dt>
              <dd class="text-[13px] leading-relaxed text-zinc-600">
                "Public" and "hidden from the server" cannot both be true, so we do not
                pretend. Public posts are stored in the clear and marked as such.
              </dd>
            </div>
          </div>
          <div class="flex gap-3">
            <span class="hero-fire-mini mt-0.5 h-4 w-4 shrink-0 text-rose-600" />
            <div>
              <dt class="text-[14px] font-semibold">Deleting destroys the keys</dt>
              <dd class="text-[13px] leading-relaxed text-zinc-600">
                Not the rows. Your data stays on disk as noise nobody can ever read —
                including us, and including you.
              </dd>
            </div>
          </div>
        </dl>
      </div>

      <div class="rounded-2xl border border-zinc-200 p-6 shadow-sm">
        <div class="flex gap-1 rounded-full bg-zinc-100 p-1 text-[14px] font-semibold">
          <button
            phx-click="mode"
            phx-value-mode="login"
            class={[
              "flex-1 rounded-full px-3 py-1.5 transition",
              if(@mode == :login, do: "bg-white shadow-sm", else: "text-zinc-500")
            ]}
          >
            Sign in
          </button>
          <button
            phx-click="mode"
            phx-value-mode="register"
            class={[
              "flex-1 rounded-full px-3 py-1.5 transition",
              if(@mode == :register, do: "bg-white shadow-sm", else: "text-zinc-500")
            ]}
          >
            Create account
          </button>
        </div>

        <div id="auth" phx-hook="Auth" class="mt-5 space-y-4">
          <label :if={@mode == :register} class="block">
            <span class="text-[13px] font-semibold">Handle</span>
            <div class="mt-1 flex items-center rounded-lg border border-zinc-300 focus-within:ring-1 focus-within:ring-zinc-400">
              <span class="pl-3 text-zinc-400">@</span>
              <input
                name="handle"
                autocomplete="username"
                placeholder="ada"
                class="w-full border-0 bg-transparent py-2 pl-1 text-[15px] focus:ring-0"
              />
            </div>
          </label>

          <label class="block">
            <span class="text-[13px] font-semibold">Recovery passphrase</span>
            <input
              name="passphrase"
              type="password"
              autocomplete="current-password"
              class="mt-1 w-full rounded-lg border-zinc-300 py-2 text-[15px]"
            />
            <span class="mt-1.5 block text-[12px] leading-relaxed text-zinc-500">
              <%= if @mode == :register do %>
                Wraps your key a second time, so losing your passkey does not lose your data.
                We keep no copy — forget it and lose your passkey, and the data is
                gone for good. That is the design working, not failing.
              <% else %>
                Only needed if your authenticator cannot produce a PRF value.
              <% end %>
            </span>
          </label>

          <button
            :if={@mode == :register}
            data-register
            class="w-full rounded-full bg-zinc-900 px-4 py-2.5 text-[15px] font-semibold text-white transition hover:bg-zinc-700 disabled:opacity-40"
          >
            Create account with a passkey
          </button>
          <button
            :if={@mode == :login}
            data-login
            class="w-full rounded-full bg-zinc-900 px-4 py-2.5 text-[15px] font-semibold text-white transition hover:bg-zinc-700 disabled:opacity-40"
          >
            Sign in with a passkey
          </button>

          <p data-status class="text-[13px] data-[kind=error]:text-rose-600"></p>
        </div>

        <p class="mt-4 border-t border-zinc-100 pt-4 text-[12px] leading-relaxed text-zinc-500">
          You will be asked for your passkey twice: once to sign in, once to unlock. The key
          lives in this tab only, so a page load loses it — deliberately.
        </p>
      </div>
    </div>
    """
  end
end
