defmodule AshCell.ObjectStore do
  @moduledoc """
  The bit of S3 this whole design rests on: **conditional writes**.

  `If-None-Match: *` makes a PUT succeed only when the key does not yet exist, and
  `If-Match: <etag>` makes it succeed only when the key still holds the version you
  read. Those two turn an object store into a linearizable compare-and-swap
  register, which is the primitive you would otherwise need Raft, etcd, or
  ZooKeeper to get.

  Works against anything S3-compatible. Tested here against MinIO.
  """

  defstruct [:endpoint, :bucket, :region, :access_key_id, :secret_access_key]

  @type t :: %__MODULE__{}

  def new(opts) do
    %__MODULE__{
      endpoint: Keyword.fetch!(opts, :endpoint),
      bucket: Keyword.fetch!(opts, :bucket),
      region: Keyword.get(opts, :region, "us-east-1"),
      access_key_id: Keyword.fetch!(opts, :access_key_id),
      secret_access_key: Keyword.fetch!(opts, :secret_access_key)
    }
  end

  @doc """
  Writes `body` to `key`.

  Options:

    * `:if_none_match` — when `true`, the write only succeeds if the key does not
      exist. A losing racer gets `{:error, :precondition_failed}`.
    * `:if_match` — an ETag; the write only succeeds if the key still holds it.

  Returns `{:ok, etag}`.
  """
  def put(store, key, body, opts \\ []) do
    headers =
      []
      |> maybe_header("if-none-match", if(opts[:if_none_match], do: "*"))
      |> maybe_header("if-match", opts[:if_match])

    request(store, :put, key, body: body, headers: headers)
    |> case do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, etag(resp)}

      # 412 is the conditional write losing. 409 is S3/MinIO reporting a
      # concurrent conditional write to the same key; for our purposes both mean
      # "someone else got there first", and the caller must not assume it won.
      {:ok, %{status: status}} when status in [409, 412] ->
        {:error, :precondition_failed}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get(store, key) do
    case request(store, :get, key) do
      {:ok, %{status: 200} = resp} -> {:ok, resp.body, etag(resp)}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(store, key) do
    case request(store, :delete, key) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Keys under `prefix`. Used to find a tenant's newest snapshot."
  def list(store, prefix) do
    # Query parameters must go through Req's `:params` so they are part of the
    # canonical request SigV4 signs. Interpolating them into the URL string
    # produces a valid-looking request that the server rejects with 403.
    Req.new(
      method: :get,
      url: "#{store.endpoint}/#{store.bucket}",
      params: [{"list-type", "2"}, {"prefix", prefix}]
    )
    |> sign(store)
    |> Req.request()
    |> case do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Regex.scan(~r|<Key>([^<]+)</Key>|, to_string(body)) |> Enum.map(&Enum.at(&1, 1))}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(store, method, key, opts \\ []) do
    Req.new(
      [method: method, url: "#{store.endpoint}/#{store.bucket}/#{key}"] ++
        Keyword.take(opts, [:body, :headers])
    )
    |> sign(store)
    |> Req.request()
  end

  defp sign(req, store) do
    Req.Request.put_new_option(req, :aws_sigv4,
      access_key_id: store.access_key_id,
      secret_access_key: store.secret_access_key,
      region: store.region,
      service: :s3
    )
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  defp etag(resp) do
    resp
    |> Req.Response.get_header("etag")
    |> List.first()
    |> case do
      nil -> nil
      tag -> String.trim(tag, "\"")
    end
  end
end
