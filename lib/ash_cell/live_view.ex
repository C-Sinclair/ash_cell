if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule AshCell.LiveView do
    @moduledoc """
    Binding a tenant inside a LiveView, and surviving the reconnect.

    ## Why mount is the wrong place to bind

    The obvious thing is to bind once in `mount/3`. It does not work, for the same
    reason a pid is the wrong tenant handle: **the binding is a pid, and the LiveView
    outlives it.**

    A LiveView process lives as long as the browser tab. Over that time its cell can
    be evicted for inactivity, restarted after a crash, or closed and reopened by a
    drain. Each of those gives the tenant a new repo instance, and a binding taken at
    mount now points at a dead one. The failure arrives much later than the cause,
    during an ordinary click, which is the worst kind.

    So bind **per callback**, from the tenant id, every time:

        defmodule MyAppWeb.PatientsLive do
          use MyAppWeb, :live_view
          on_mount {AshCell.LiveView, :bind_tenant}

          def mount(_params, session, socket) do
            {:ok, assign(socket, :tenant, session["tenant"])}
          end
        end

    The hook attaches to `handle_params`, `handle_event`, and `handle_info` and
    re-binds before each, resolving the tenant id afresh. Re-binding is cheap: a
    registry lookup and a process-dictionary write.

    ## Holders, not bind counts

    Bracketing each callback would leave the count at zero between them, so a drain
    would see an idle cell and take it from a user who is sitting right there. The
    hook registers the LiveView as a *holder* instead (`AshCell.Holders`), which
    persists between callbacks and is cleaned up automatically when the tab closes.

    ## What happens on deploy

    The socket drops. That cannot be prevented — the node is going away, and no
    amount of routing keeps a TCP connection alive across it. Three things can be
    made better, and are:

      1. **Where the reconnect lands.** `AshCell.Plug.OwnerRouting` inspects the
         lease during the websocket upgrade and replays the request to whichever
         node owns the cell, so the client does not bounce between nodes discovering
         ownership by trial and error.
      2. **When it happens.** Draining warns holders before the socket is severed
         (`AshCell.Drain`), with jitter, so a fleet of tabs reconnects over a spread
         of seconds instead of stampeding a cold node in one instant.
      3. **What it costs the user.** LiveView re-mounts and recovers form state on
         its own, provided forms are set up for it. That is standard LiveView, not
         something this library adds — but it is the difference between a flicker and
         lost work, so it is worth checking rather than assuming.
    """

    import Phoenix.LiveView
    import Phoenix.Component, only: [assign: 3]

    @doc """
    `on_mount` hook binding the socket's tenant before every callback.

    Reads the tenant from `socket.assigns.tenant`, falling back to `session["tenant"]`
    and then to the `"tenant"` param, so it works whether the tenant comes from the
    session, the URL, or an earlier hook.
    """
    def on_mount(:bind_tenant, params, session, socket) do
      case resolve(socket, params, session) do
        nil ->
          # Failing here is deliberate. A LiveView with no tenant will otherwise
          # query whatever the process happens to be bound to, which in the worst
          # case is another tenant's data.
          {:halt, redirect_missing(socket)}

        tenant ->
          socket =
            socket
            |> assign(:tenant, tenant)
            |> bind_now(tenant)
            |> attach_hook(:ash_cell_bind, :handle_params, &rebind_params/3)
            |> attach_hook(:ash_cell_bind_event, :handle_event, &rebind_event/3)
            |> attach_hook(:ash_cell_bind_info, :handle_info, &rebind_info/2)

          {:cont, socket}
      end
    end

    @doc """
    Binds `tenant` for this LiveView process and registers it as a holder.

    Safe to call repeatedly — that is the normal case, once per callback.
    """
    def bind_now(socket, tenant) do
      case AshCell.bind_held(tenant) do
        :ok ->
          socket

        {:error, :draining} ->
          # The node is on its way out. Reconnecting now lands somewhere that can
          # actually serve, rather than waiting to be cut off mid-interaction.
          request_reconnect(socket)

        {:error, reason} ->
          assign(socket, :ash_cell_error, reason)
      end
    end

    defp rebind_params(_params, _uri, socket),
      do: {:cont, bind_now(socket, socket.assigns.tenant)}

    defp rebind_event(_event, _params, socket),
      do: {:cont, bind_now(socket, socket.assigns.tenant)}

    defp rebind_info({:ash_cell, :drain_imminent, _tenant}, socket) do
      {:halt, request_reconnect(socket)}
    end

    defp rebind_info(_message, socket), do: {:cont, bind_now(socket, socket.assigns.tenant)}

    # Asking the client to reconnect *before* the socket is severed is what turns a
    # deploy from an abrupt drop into a controlled handover: the browser reconnects
    # while this node can still answer, and lands on the node that now owns the cell.
    defp request_reconnect(socket) do
      socket
      |> assign(:ash_cell_reconnecting, true)
      |> push_event("ash_cell:reconnect", %{reason: "draining"})
    end

    defp resolve(socket, params, session) do
      socket.assigns[:tenant] || session["tenant"] || params_tenant(params)
    end

    defp params_tenant(params) when is_map(params), do: params["tenant"]
    defp params_tenant(_), do: nil

    defp redirect_missing(socket) do
      socket
      |> Phoenix.LiveView.put_flash(:error, "No tenant for this session.")
      |> Phoenix.LiveView.redirect(to: "/")
    end
  end
end
