defmodule ShroudWeb.AudienceActions do
  @moduledoc """
  Adding and removing audience members, shared by the pages that offer it.

  ## Why adding somebody is a round trip

  The server cannot do this on its own, and that is the design working rather than an
  awkwardness to hide. Adding Bob to Alice's "Friends" means sealing that audience's
  group key to Bob's public key — and the group key only exists in plaintext inside
  Alice's browser. So:

      LiveView  -> push_event "seal_group_key_for"  (here is Bob's public key)
      browser   -> unwraps the group key under MK, seals it to Bob, pushes it back
      LiveView  -> stores an opaque blob it cannot read

  Three hops instead of one database write, because the server is not able to take the
  shortcut. Any design where the server *could* do this in one step is a design where
  the server can read your data.
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]

  alias Shroud.Global
  alias Shroud.Profiles

  require Ash.Query

  @doc "Step 1: look up the member and ask the browser to seal the group key to them."
  def request_seal(socket, handle, slug, audiences) do
    handle = handle |> to_string() |> String.trim() |> String.trim_leading("@")

    case Global.User |> Ash.Query.filter(handle == ^handle) |> Ash.read_one!() do
      nil ->
        {:noreply, put_flash(socket, :error, "No user @#{handle}.")}

      %{id: id} when id == socket.assigns.current_user.id ->
        {:noreply, put_flash(socket, :error, "You do not need to add yourself.")}

      %{public_key: nil} ->
        # Without a published public key there is nothing to seal to. Seeded fixtures
        # can hit this; a real registration always publishes one.
        {:noreply, put_flash(socket, :error, "@#{handle} has no published public key.")}

      member ->
        case Enum.find(audiences, &(&1.slug == slug)) do
          nil ->
            {:noreply, put_flash(socket, :error, "Unknown audience.")}

          audience ->
            {:noreply,
             socket
             |> push_event("seal_group_key_for", %{
               slug: slug,
               member_id: member.id,
               public_key: member.public_key,
               wrapped: %{wrapped_group_key: audience.wrapped_group_key, iv: audience.iv}
             })
             |> assign(pending_member: {slug, member.id})}
        end
    end
  end

  @doc "Step 3: store what the browser sealed. Opaque to us."
  def store_seal(socket, %{"slug" => slug, "member_id" => member_id, "sealed" => sealed}, reload) do
    case Profiles.add_member(socket.assigns.current_user.id, slug, member_id, sealed) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Added.") |> then(reload)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, describe(reason))}
    end
  end

  @doc "Removes a member. See `Shroud.Profiles.remove_member/3` for what this does not do."
  def remove(socket, slug, member_id, reload) do
    :ok = Profiles.remove_member(socket.assigns.current_user.id, slug, member_id)
    {:noreply, socket |> put_flash(:info, "Removed.") |> then(reload)}
  end

  # An identity clash means they are already in that audience at this generation, which
  # is not worth an error message.
  defp describe(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidChanges{}, &1)) do
      "Already in that audience."
    else
      "Could not add them."
    end
  end

  defp describe(_other), do: "Could not add them."
end
