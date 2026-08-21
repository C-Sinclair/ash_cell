defmodule ShroudWeb.SettingsLive do
  @moduledoc """
  Audience membership, and account deletion.

  The deletion screen is the one place where the honest caveats have to be in the
  UI rather than the docs. Its copy comes from `Shroud.Shred.impact/1` rather than
  being written into the template, so that if the shred changes and this screen stops
  making sense, the mismatch shows up here instead of quietly misleading somebody
  about what deleting their account did.
  """
  use ShroudWeb, :live_view

  alias Shroud.Global
  alias Shroud.Profiles
  alias Shroud.Shred

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(confirming?: false) |> load()}
  end

  @impl true
  def handle_event("unlocked", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, confirming?: true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirming?: false)}
  end

  # Adding a member needs the group key, and the group key is only available in the
  # browser. So the server asks the client to do the sealing and hands back the
  # result -- the round trip is the price of the server not being able to do it.
  def handle_event("add_member", %{"handle" => handle, "slug" => slug}, socket) do
    case Global.User |> Ash.Query.filter(handle == ^handle) |> Ash.read_one!() do
      nil ->
        {:noreply, put_flash(socket, :error, "No user @#{handle}.")}

      %{public_key: nil} ->
        {:noreply, put_flash(socket, :error, "@#{handle} has no published public key.")}

      member ->
        audience = Enum.find(socket.assigns.audiences, &(&1.slug == slug))

        {:noreply,
         push_event(socket, "seal_group_key_for", %{
           slug: slug,
           member_id: member.id,
           public_key: member.public_key,
           wrapped: %{wrapped_group_key: audience.wrapped_group_key, iv: audience.iv}
         })
         |> assign(pending_member: {slug, member.id})}
    end
  end

  def handle_event(
        "member_sealed",
        %{"slug" => slug, "member_id" => member_id, "sealed" => sealed},
        socket
      ) do
    owner = socket.assigns.current_user

    case Profiles.add_member(owner.id, slug, member_id, sealed) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Added.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("cryptoshred", _params, socket) do
    user = socket.assigns.current_user

    case Shred.cryptoshred(user.id) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} key wraps destroyed. Your data is now unreadable.")
         |> redirect(to: "/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user

    members =
      Global.AudienceMember
      |> Ash.Query.filter(owner_id == ^user.id)
      |> Ash.Query.load(:member)
      |> Ash.read!()

    assign(socket,
      audiences: Profiles.audiences(user.id),
      members: Enum.group_by(members, & &1.audience_id),
      impact: Shred.impact(user.id)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell current="settings" user={@current_user} title="Settings">
      <.unlock_panel />

      <section id="audiences" phx-hook="Audiences" class="border-b border-zinc-200 px-4 py-4">
        <h2 class="text-[15px] font-bold">Audiences</h2>
        <p class="mt-1 text-[13px] leading-relaxed text-zinc-500">
          Adding someone seals this audience's group key to their public key — one wrap,
          once. They can then read everything you share with the audience, including things
          you share later, without you being online.
        </p>

        <div class="mt-3 flex gap-2">
          <input
            name="audience_name"
            placeholder="Friends"
            class="min-w-0 flex-1 rounded-full border-zinc-300 px-3 py-1.5 text-[14px]"
          />
          <button
            data-new-audience
            class="rounded-full bg-zinc-900 px-4 py-1.5 text-[14px] font-semibold text-white hover:bg-zinc-700"
          >
            Add
          </button>
        </div>

        <div class="mt-4 space-y-3">
          <div :for={a <- @audiences} class="rounded-xl border border-zinc-200 p-3">
            <div class="flex items-center gap-2">
              <span class="hero-lock-closed-mini h-4 w-4 text-emerald-700" />
              <h3 class="text-[14px] font-semibold">{a.name}</h3>
              <span class="text-[12px] text-zinc-400">generation {a.generation}</span>
            </div>

            <ul class="mt-2 flex flex-wrap gap-1.5">
              <li
                :for={m <- Map.get(@members, a.slug, [])}
                class="inline-flex items-center gap-1 rounded-full bg-zinc-100 px-2 py-0.5 text-[13px]"
              >
                <.avatar handle={m.member.handle} size="5" />@{m.member.handle}
              </li>
              <li :if={Map.get(@members, a.slug, []) == []} class="text-[13px] text-zinc-400">
                no members yet
              </li>
            </ul>

            <form phx-submit="add_member" class="mt-3 flex gap-2">
              <input type="hidden" name="slug" value={a.slug} />
              <input
                name="handle"
                placeholder="handle to add"
                class="min-w-0 flex-1 rounded-full border-zinc-300 px-3 py-1.5 text-[14px]"
              />
              <button class="rounded-full border border-zinc-300 px-3 py-1.5 text-[14px] font-semibold hover:bg-zinc-50">
                Add
              </button>
            </form>
          </div>

          <p :if={@audiences == []} class="text-[13px] text-zinc-500">
            None yet. Until you make one, you can only post publicly.
          </p>
        </div>
      </section>

      <section class="px-4 py-5">
        <h2 class="text-[15px] font-bold text-rose-700">Delete account</h2>

        <div :if={!@confirming?} class="mt-2">
          <p class="text-[13px] leading-relaxed text-zinc-600">
            Destroys every wrapped copy of your master key — there {if length(@impact.wraps) == 1,
              do: "is",
              else: "are"} {length(@impact.wraps)} ({Enum.map_join(@impact.wraps, ", ", &to_string/1)}). Your data stays on disk and
            becomes permanently unreadable, by anyone, including us.
          </p>
          <button
            phx-click="confirm_delete"
            class="mt-3 rounded-full border border-rose-300 px-4 py-1.5 text-[14px] font-semibold text-rose-700 hover:bg-rose-50"
          >
            Delete my account
          </button>
        </div>

        <div :if={@confirming?} class="mt-3 rounded-xl border border-rose-300 bg-rose-50 p-4">
          <p class="text-[14px] font-semibold">This cannot be undone by anyone, including us.</p>

          <p class="mt-3 text-[13px] font-semibold">Immediately unreadable</p>
          <ul class="mt-1 space-y-0.5">
            <li
              :for={line <- @impact.unreachable_after}
              class="flex gap-1.5 text-[13px] text-zinc-700"
            >
              <span class="hero-x-mark-mini mt-0.5 h-3.5 w-3.5 shrink-0 text-rose-600" />{line}
            </li>
          </ul>

          <p class="mt-3 text-[13px] font-semibold">What this does not reach</p>
          <ul class="mt-1 space-y-0.5">
            <li :for={line <- @impact.survives} class="flex gap-1.5 text-[13px] text-zinc-700">
              <span class="hero-exclamation-triangle-mini mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-600" />{line}
            </li>
          </ul>

          <div class="mt-4 flex gap-2">
            <button
              phx-click="cryptoshred"
              class="rounded-full bg-rose-700 px-4 py-1.5 text-[14px] font-semibold text-white hover:bg-rose-800"
            >
              Destroy my keys
            </button>
            <button
              phx-click="cancel_delete"
              class="rounded-full border border-zinc-300 px-4 py-1.5 text-[14px] font-semibold hover:bg-white"
            >
              Cancel
            </button>
          </div>
        </div>
      </section>

      <:aside>
        <.key_panel />
      </:aside>
    </.shell>
    """
  end
end
