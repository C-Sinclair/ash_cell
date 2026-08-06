if Code.ensure_loaded?(Plug) do
  defmodule AshCell.Plug.OwnerRouting do
    @moduledoc """
    Sends a request to the node that owns the tenant's cell.

    ## Why this is the right place

    A cell can only be open on one node. A request that lands anywhere else has
    three options: proxy every query across the network (throwing away the
    colocation that makes this architecture worth having), steal the lease (a
    handover per request, thrashing between nodes), or send the *request* to the
    data. The third is the only one that keeps the property the design is built on.

    The websocket upgrade is an ordinary HTTP request, so it can be routed the same
    way as any other. That matters for reconnects: it is the difference between a
    client landing on the owner first time, and bouncing between nodes discovering
    ownership by trial and error while a user watches a spinner.

    ## Two transports

      * **Fly.io** — respond with `fly-replay`, and the platform re-issues the
        request against the named instance. No proxying, no extra hop.
      * **Anything else** — a `redirect_to` callback, or none at all, in which case
        the request is served locally and the local node takes the lease. That is
        correct for single-node deployments and for development, which is why it is
        the default rather than an error.

    ## Usage

        plug AshCell.Plug.OwnerRouting,
          tenant: &MyAppWeb.Tenancy.from_conn/1,
          store: {MyApp.ObjectStore, :config, []}

    ## What it deliberately does not do

    It does not *wait* for ownership to settle. If the lease is unclaimed, this node
    takes it and serves. Blocking a user's request on a distributed handover is
    slower than the handover is worth, and the lease is an optimisation rather than
    a correctness boundary — a race here costs a redundant rehydrate, not data.
    """
    @behaviour Plug

    require Logger

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      with {:ok, tenant} <- fetch_tenant(conn, opts),
           store when not is_nil(store) <- resolve_store(opts),
           {:ok, owner} <- AshCell.Lease.holder(store, tenant),
           false <- owner == local_owner(opts) do
        route_elsewhere(conn, owner, opts)
      else
        _ -> conn
      end
    end

    defp route_elsewhere(conn, owner, opts) do
      case Keyword.get(opts, :transport, :fly) do
        :fly ->
          conn
          |> Plug.Conn.put_resp_header("fly-replay", "instance=#{owner}")
          |> Plug.Conn.send_resp(307, "")
          |> Plug.Conn.halt()

        {:redirect, fun} when is_function(fun, 2) ->
          conn
          |> Plug.Conn.put_resp_header("location", fun.(conn, owner))
          |> Plug.Conn.send_resp(307, "")
          |> Plug.Conn.halt()

        :none ->
          conn
      end
    end

    defp fetch_tenant(conn, opts) do
      case Keyword.get(opts, :tenant) do
        fun when is_function(fun, 1) ->
          case fun.(conn) do
            nil -> :error
            tenant -> {:ok, tenant}
          end

        nil ->
          :error
      end
    end

    defp resolve_store(opts) do
      case Keyword.get(opts, :store) do
        {mod, fun, args} -> apply(mod, fun, args)
        nil -> safe_manager_store()
        store -> store
      end
    end

    # The manager may not be running yet during boot, and a request arriving then
    # should be served rather than 500.
    defp safe_manager_store do
      AshCell.Manager.store()
    catch
      :exit, _ -> nil
    end

    defp local_owner(opts), do: Keyword.get(opts, :owner, to_string(node()))
  end
end
