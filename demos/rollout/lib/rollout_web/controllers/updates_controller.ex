defmodule RolloutWeb.UpdatesController do
  @moduledoc """
  The device-facing half of the API: one endpoint, and it never writes.

  Modelled on what a real OTA client sends — what it *is*, and what it already has
  — rather than on an identifier the server has to look up. That is what makes the
  read path cacheable: the answer depends on the channel's pointer, not on any
  per-device state, so one published manifest serves the whole fleet and the
  request volume never reaches the cell's single connection.
  """
  use RolloutWeb, :controller

  alias Rollout.Resolve

  def check(conn, params) do
    with {:ok, channel} <- fetch(params, "channel"),
         {:ok, device_id} <- fetch(params, "device_id"),
         {:ok, runtime} <- fetch_runtime(params) do
      checkin = %{
        device_id: device_id,
        platform: atomise(params["platform"] || "ios", [:ios, :android]),
        arch: params["arch"] || "arm64",
        runtime: runtime,
        current_release: params["current_release"]
      }

      respond(conn, channel, checkin)
    else
      {:error, message} -> error(conn, 422, message)
    end
  end

  @max_batch 2_000

  @doc """
  Resolves many check-ins in one request, and reports what they cost.

  A load-generation affordance, and it exists for a specific reason: a browser holds
  about six connections per host, so a page cannot issue hundreds of check-ins a
  second one at a time — it would be measuring the browser's connection pool, not
  the cell. Every entry in the response is a real resolve against the real channel,
  and `elapsed_us` is the time the whole batch took, so the throughput on screen is
  measured rather than asserted.

  Returns counts per version rather than a row per device. The visualiser only needs
  the distribution to draw from, and a row per device at this rate is bandwidth spent
  on nothing.
  """
  def check_batch(conn, params) do
    with {:ok, channel} <- fetch(params, "channel"),
         {:ok, runtime} <- fetch_runtime(params) do
      count = params["count"] |> to_count() |> min(@max_batch)
      offset = to_count(params["offset"])

      checkin = fn n ->
        %{
          device_id: "phone-#{offset + n}",
          platform: atomise(params["platform"] || "ios", [:ios, :android]),
          arch: params["arch"] || "arm64",
          runtime: runtime,
          current_release: nil
        }
      end

      {elapsed, tally} =
        :timer.tc(fn ->
          Enum.reduce(1..count, %{}, fn n, tally ->
            key =
              case Resolve.check(channel, checkin.(n)) do
                {:update, %{version: version}} -> version
                :up_to_date -> "up_to_date"
                :no_release -> "no_release"
              end

            Map.update(tally, key, 1, &(&1 + 1))
          end)
        end)

      json(conn, %{
        channel: channel,
        count: count,
        elapsed_us: elapsed,
        per_resolve_us: Float.round(elapsed / max(count, 1), 3),
        versions: tally
      })
    else
      {:error, message} -> error(conn, 422, message)
    end
  end

  defp to_count(value) when is_integer(value) and value > 0, do: value

  defp to_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp to_count(_), do: 1

  defp respond(conn, channel, checkin) do
    case Resolve.check(channel, checkin) do
      :no_release ->
        json(conn, %{status: "no_release", channel: channel})

      :up_to_date ->
        # A device outside a staged rollout gets the same answer as a device that
        # is already current. Deliberate: telling it that it was excluded would
        # leak the rollout shape to every client and invite retry storms at the
        # boundary.
        json(conn, %{status: "up_to_date", channel: channel})

      {:update, manifest} ->
        json(conn, %{
          status: "update",
          channel: channel,
          release_id: manifest.release_id,
          version: manifest.version,
          artifacts: Enum.map(manifest.artifacts, &artifact/1)
        })
    end
  end

  # `url` is where the blob would be fetched from, and it is a placeholder: this
  # demo stores no bytes. Named in the response rather than omitted, because the
  # shape of the answer is part of what the demo is showing.
  defp artifact(artifact) do
    %{
      blob_hash: artifact.blob_hash,
      kind: artifact.kind,
      size: artifact.size,
      url: "/blobs/#{artifact.blob_hash}"
    }
  end

  defp fetch(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  # Runtime versions arrive as "1.4.2" from a client and as an integer from a
  # script. Both are accepted, and both end up as the integer the artifact bounds
  # are stored as, because the resolve path must not pay for parsing per read.
  defp fetch_runtime(params) do
    case params["runtime"] do
      nil -> {:error, "runtime is required"}
      n when is_integer(n) -> {:ok, n}
      s when is_binary(s) -> parse_runtime(s)
      _ -> {:error, "runtime must be an integer or a version string"}
    end
  end

  defp parse_runtime(string) do
    case Integer.parse(string) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case String.split(string, ".") do
          [major, minor | _] ->
            with {major, ""} <- Integer.parse(major),
                 {minor, ""} <- Integer.parse(minor) do
              {:ok, major * 100 + minor}
            else
              _ -> {:error, "runtime #{inspect(string)} is not a version"}
            end

          _ ->
            {:error, "runtime #{inspect(string)} is not a version"}
        end
    end
  end

  defp atomise(value, allowed) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
