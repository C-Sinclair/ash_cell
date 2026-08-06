defmodule AshCell.Sim.Store do
  @moduledoc """
  A pure model of a conditional-write object store.

  No processes, no network, no time. Every operation is a function from state to
  `{result, state}`, which is what makes a whole run reproducible from a seed.

  This encodes what we *believe* S3, R2, and Tigris do. That belief is the
  weakest link in the whole scheme: if it is wrong, the simulator will agree with
  us confidently and at scale. It has to be checked against real providers
  separately — see the conformance note in `docs/dst.md`.
  """

  defstruct objects: %{}, faults: [], log: []

  @type result :: {:ok, etag :: String.t()} | {:error, :precondition_failed | :not_found | :unavailable}

  def new(opts \\ []), do: %__MODULE__{faults: Keyword.get(opts, :faults, [])}

  @doc """
  Writes `key`, subject to a precondition.

    * `if_none_match: true` — create only. The primitive behind lease claims and
      generation-keyed durability writes.
    * `if_match: etag` — compare-and-swap. The primitive behind lease renewal.
    * neither — unconditional.
  """
  def put(store, key, body, opts \\ []) do
    case take_fault(store) do
      {:some, fault, store} ->
        {{:error, fault}, log(store, {:put, key, {:fault, fault}})}

      {:none, store} ->
        do_put(store, key, body, opts)
    end
  end

  defp do_put(store, key, body, opts) do
    current = Map.get(store.objects, key)

    cond do
      Keyword.get(opts, :if_none_match, false) and current != nil ->
        {{:error, :precondition_failed}, log(store, {:put, key, :refused_exists})}

      (expected = Keyword.get(opts, :if_match)) && etag_of(current) != expected ->
        {{:error, :precondition_failed}, log(store, {:put, key, :refused_etag})}

      true ->
        etag = "etag-#{map_size(store.objects)}-#{:erlang.phash2(body)}"
        objects = Map.put(store.objects, key, %{body: body, etag: etag})
        {{:ok, etag}, log(%{store | objects: objects}, {:put, key, :ok})}
    end
  end

  def get(store, key) do
    case Map.get(store.objects, key) do
      nil -> {{:error, :not_found}, log(store, {:get, key, :missing})}
      %{body: body, etag: etag} -> {{:ok, body, etag}, log(store, {:get, key, :ok})}
    end
  end

  def delete(store, key) do
    {:ok, log(%{store | objects: Map.delete(store.objects, key)}, {:delete, key, :ok})}
  end

  def list(store, prefix) do
    store.objects |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()
  end

  defp etag_of(nil), do: nil
  defp etag_of(%{etag: etag}), do: etag

  # Faults are a scripted list rather than random draws, so a Stage 0 test states
  # exactly which operation fails. The simulator proper draws them from the seed.
  defp take_fault(%{faults: [fault | rest]} = store), do: {:some, fault, %{store | faults: rest}}
  defp take_fault(%{faults: []} = store), do: {:none, store}

  defp log(store, entry), do: %{store | log: [entry | store.log]}

  @doc "Operations applied so far, oldest first."
  def history(store), do: Enum.reverse(store.log)
end
