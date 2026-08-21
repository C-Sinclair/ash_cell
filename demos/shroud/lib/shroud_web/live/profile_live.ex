defmodule ShroudWeb.ProfileLive do
  @moduledoc """
  The owner's own profile: edit fields, pick who sees each one.

  Every field renders as ciphertext with its own wrapped content key attached, and
  the `OwnProfile` hook decrypts in place. So the HTML this LiveView pushes contains
  no profile data — inspect the websocket frames and there is nothing to read, which
  is the claim the whole app exists to make and worth being able to demonstrate live.

  Saving goes the other way: the hook encrypts, wraps the content key once per
  selected audience, and pushes the sealed result. `handle_event("put_field", …)`
  stores bytes it cannot interpret.
  """
  use ShroudWeb, :live_view

  alias Shroud.Profiles

  @slots [
    {"display_name", "Display name"},
    {"birthday", "Birthday"},
    {"bio", "Bio"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("unlocked", _params, socket) do
    {:noreply, assign(socket, locked?: false)}
  end

  def handle_event("put_audience", params, socket) do
    Profiles.put_audience(socket.assigns.current_user.id, %{
      slug: params["slug"],
      name: params["name"],
      wrapped_group_key: params["wrapped_group_key"],
      iv: params["iv"]
    })

    {:noreply, load(socket)}
  end

  def handle_event("put_field", params, socket) do
    field = params["field"]
    own = params["own_wrap"]

    grants =
      Enum.map(params["grants"] || [], fn g ->
        %{
          field_key: g["field_key"],
          audience_slug: g["audience_slug"],
          wrapped_content_key: g["wrapped_content_key"],
          iv: g["iv"]
        }
      end)

    # The owner's own wrap is stored as a grant to a reserved audience. Keeping it in
    # the same table as every other grant means one read path instead of two, and
    # rules out the failure where an owner can share a field but not read it back.
    self_grant = %{
      field_key: field["key"],
      audience_slug: "__self",
      wrapped_content_key: own["wrapped_content_key"],
      iv: own["iv"]
    }

    case Profiles.put_field(
           socket.assigns.current_user.id,
           %{
             key: field["key"],
             ciphertext: field["ciphertext"],
             iv: field["iv"],
             content_key_id: field["content_key_id"]
           },
           [self_grant | grants]
         ) do
      {:ok, _field} -> {:noreply, socket |> put_flash(:info, "Saved.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user

    assign(socket,
      slots: @slots,
      fields: Map.new(Profiles.editable_fields(user.id), &{&1.key, &1}),
      grants: Enum.group_by(Profiles.own_grants(user.id), & &1.field_key),
      audiences: Profiles.audiences(user.id),
      posts: Profiles.timeline(user.id, limit: 50) |> Enum.filter(& &1.own?),
      page_title: "Your profile"
    )
  end

  defp own_wrap(grants, key) do
    grants
    |> Map.get(key, [])
    |> Enum.find(&(&1.audience_slug == "__self"))
    |> case do
      nil -> nil
      g -> Jason.encode!(%{wrapped_content_key: g.wrapped_content_key, iv: g.iv})
    end
  end

  defp shared_with?(grants, key, slug) do
    grants |> Map.get(key, []) |> Enum.any?(&(&1.audience_slug == slug))
  end

  defp field_json(nil), do: nil

  defp field_json(field),
    do: Jason.encode!(%{key: field.key, ciphertext: field.ciphertext, iv: field.iv})

  @impl true
  def render(assigns) do
    ~H"""
    <.shell current="profile" user={@current_user} title="Your profile">
      <.unlock_panel />

      <div class="flex items-start gap-4 border-b border-zinc-200 px-4 py-5">
        <.avatar handle={@current_user.handle} size="16" />
        <div class="min-w-0">
          <p class="text-[19px] font-bold">@{@current_user.handle}</p>
          <p class="mt-0.5 text-[13px] text-zinc-500">
            {length(@audiences)} {if length(@audiences) == 1, do: "audience", else: "audiences"} ·
            joined {ago(@current_user.inserted_at)} ago
          </p>
        </div>
      </div>

      <section class="border-b border-zinc-200 px-4 py-4">
        <h2 class="flex items-center gap-1.5 text-[15px] font-bold">
          <span class="hero-lock-closed-mini h-4 w-4 text-emerald-700" /> Your details
        </h2>
        <p class="mt-1 text-[13px] leading-relaxed text-zinc-500">
          Encrypted in this tab before it is sent. Tick an audience to wrap the key for
          them — they can then read it even when you are offline.
        </p>

        <div id="own-profile" phx-hook="OwnProfile" class="mt-4 space-y-4">
          <div
            :for={{key, label} <- @slots}
            data-field-row
            data-field-key={key}
            data-field={field_json(@fields[key])}
            data-own-wrap={own_wrap(@grants, key)}
            class="rounded-xl border border-zinc-200 p-3"
          >
            <label class="block text-[13px] font-semibold text-zinc-700">{label}</label>
            <input
              data-value
              placeholder={if @fields[key], do: "decrypting…", else: "not set"}
              class="mt-1 w-full rounded-lg border-zinc-300 text-[15px]"
            />

            <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1.5">
              <label :for={a <- @audiences} class="flex items-center gap-1.5 text-[13px]">
                <input
                  type="checkbox"
                  data-audience={a.slug}
                  data-wrapped-group-key={
                    Jason.encode!(%{wrapped_group_key: a.wrapped_group_key, iv: a.iv})
                  }
                  checked={shared_with?(@grants, key, a.slug)}
                  class="rounded border-zinc-300 text-zinc-900 focus:ring-zinc-400"
                />
                {a.name}
              </label>
              <span :if={@audiences == []} class="text-[13px] text-zinc-400">
                no audiences — only you can read this
              </span>
              <button
                data-save
                class="ml-auto rounded-full bg-zinc-900 px-3 py-1.5 text-[13px] font-semibold text-white hover:bg-zinc-700"
              >
                Save
              </button>
            </div>
          </div>
        </div>
      </section>

      <h2 class="px-4 pb-2 pt-4 text-[15px] font-bold">Your posts</h2>
      <div id="own-posts" phx-hook="Timeline">
        <.post_card :for={post <- @posts} post={post} />
        <.empty :if={@posts == []} title="No posts yet" icon="hero-chat-bubble-oval-left">
          Anything you post shows up here, public or encrypted.
        </.empty>
      </div>

      <:aside>
        <.key_panel />
        <div class="mt-4 rounded-2xl border border-zinc-200 p-4">
          <h2 class="text-[14px] font-bold">Why two prompts</h2>
          <p class="mt-1 text-[12px] leading-relaxed text-zinc-500">
            Signing in proves who you are. Unlocking hands your browser the key. A passkey
            does both jobs with one gesture, but the key cannot survive a page load without
            being cached somewhere — and caching it is what this app is built to avoid.
          </p>
        </div>
      </:aside>
    </.shell>
    """
  end
end
