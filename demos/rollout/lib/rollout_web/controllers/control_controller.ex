defmodule RolloutWeb.ControlController do
  @moduledoc """
  The operator half: cut a release, promote it, ramp it, roll it back.

  Every route here is a write on one channel cell, and there is no authentication
  on any of them — this is a demo, and saying so is cheaper than pretending
  otherwise. The channel is a glob segment because a channel name contains a
  slash (`myapp/prod`), which is the shape a real fleet uses.
  """
  use RolloutWeb, :controller

  alias Rollout.Control

  def index(conn, _params) do
    json(conn, %{channels: Enum.map(Rollout.Cells.channels(), &describe/1)})
  end

  def show(conn, %{"channel" => segments}) do
    json(conn, describe(join(segments)))
  end

  def cut(conn, %{"channel" => segments} = params) do
    channel = join(segments)

    with {:ok, version} <- fetch(params, "version"),
         {:ok, artifacts} <- artifacts(params) do
      case Control.cut(channel, version, artifacts, notes: params["notes"]) do
        {:ok, release} ->
          conn
          |> put_status(201)
          |> json(%{release_id: release.id, version: release.version, state: release.state})

        {:error, reason} ->
          error(conn, 422, inspect(reason))
      end
    else
      {:error, message} -> error(conn, 422, message)
    end
  end

  def promote(conn, %{"channel" => segments} = params) do
    channel = join(segments)

    with {:ok, release_id} <- fetch(params, "release_id") do
      run(conn, channel, fn ->
        Control.promote(channel, release_id,
          rollout: rollout(params),
          reason: params["reason"]
        )
      end)
    else
      {:error, message} -> error(conn, 422, message)
    end
  end

  def upgrade(conn, %{"channel" => segments} = params) do
    channel = join(segments)
    run(conn, channel, fn -> Control.upgrade(channel, reason: params["reason"]) end)
  end

  def ramp(conn, %{"channel" => segments} = params) do
    channel = join(segments)
    run(conn, channel, fn -> Control.ramp(channel, rollout(params)) end)
  end

  def rollback(conn, %{"channel" => segments} = params) do
    channel = join(segments)
    run(conn, channel, fn -> Control.rollback(channel, reason: params["reason"]) end)
  end

  def collectable(conn, %{"channel" => segments} = params) do
    channel = join(segments)
    keep = params |> Map.get("keep", "3") |> to_integer(3)

    json(conn, %{
      channel: channel,
      keep: keep,
      blobs: Control.collectable_blobs(channel, keep: keep)
    })
  end

  # The response to every write is the channel's new state, so a curl session can
  # see what changed without a second request -- and so a rollback's effect is
  # visible in the same output that caused it.
  defp run(conn, channel, fun) do
    case fun.() do
      {:ok, _} -> json(conn, describe(channel))
      {:error, reason} -> error(conn, 409, inspect(reason))
    end
  end

  defp describe(channel) do
    pointer = Control.current_pointer(channel)

    # Read before resolving, because resolving *populates*: this field is the cache's
    # state as the request arrived, and answering the request warms it. Reporting it
    # the other way round would make every response say `true` and the field
    # worthless.
    cached? = match?({:ok, _}, AshCell.ReadCache.fetch(channel, :manifest))
    manifest = Rollout.Resolve.manifest(channel)

    %{
      channel: channel,
      release_id: pointer && pointer.release_id,
      version: manifest.version,
      rollout: (pointer && pointer.rollout) || 0,
      cached: cached?,
      history:
        Enum.map(Control.history(channel, 10), fn entry ->
          %{
            kind: entry.kind,
            release_id: entry.release_id,
            from_release_id: entry.from_release_id,
            rollout: entry.rollout,
            reason: entry.reason,
            at: entry.inserted_at
          }
        end)
    }
  end

  defp artifacts(params) do
    case params["artifacts"] do
      list when is_list(list) and list != [] -> {:ok, Enum.map(list, &artifact/1)}
      _ -> {:error, "artifacts must be a non-empty list"}
    end
  end

  defp artifact(attrs) do
    %{
      blob_hash: attrs["blob_hash"],
      kind: String.to_existing_atom(attrs["kind"] || "bundle"),
      platform: String.to_existing_atom(attrs["platform"] || "ios"),
      arch: attrs["arch"] || "arm64",
      size: to_integer(attrs["size"], 0),
      min_runtime: to_integer(attrs["min_runtime"], 140),
      max_runtime: attrs["max_runtime"] && to_integer(attrs["max_runtime"], nil)
    }
  end

  defp rollout(params), do: params |> Map.get("rollout", 100) |> to_integer(100)

  defp to_integer(value, _default) when is_integer(value), do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp to_integer(_value, default), do: default

  defp fetch(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp join(segments) when is_list(segments), do: Enum.join(segments, "/")
  defp join(segment), do: segment

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
