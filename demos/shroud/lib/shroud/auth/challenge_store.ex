defmodule Shroud.Auth.ChallengeStore do
  @moduledoc """
  Short-lived, single-use storage for in-flight WebAuthn challenges.

  The obvious home would be the Plug session, and for a bare challenge it would be
  fine. But `Wax.Challenge` carries the full `allow_credentials` list, which for a
  usernameless login is *every* credential the server knows about — that outgrows a
  4KB signed cookie almost immediately. So the cookie holds a random token and the
  struct lives here.

  Single-use is enforced by `take/1` deleting as it reads. A challenge that could be
  replayed would let a captured assertion be submitted twice, which is the whole
  thing a challenge exists to prevent.

  Entries expire on a sweep rather than only on use, because most ceremonies are
  abandoned rather than completed — a user who dismisses the passkey prompt leaves a
  challenge behind, and without a sweep those accumulate for the life of the node.
  """
  use GenServer

  @table :shroud_challenges
  @ttl_ms :timer.minutes(5)
  @sweep_ms :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Stores a challenge and returns the token that retrieves it."
  def put(challenge) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    :ets.insert(@table, {token, challenge, expiry()})
    token
  end

  @doc "Retrieves and consumes a challenge. A token is good for exactly one ceremony."
  def take(nil), do: :error

  def take(token) do
    case :ets.take(@table, token) do
      [{^token, challenge, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, challenge}, else: :error

      [] ->
        :error
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp expiry, do: System.monotonic_time(:millisecond) + @ttl_ms
end
