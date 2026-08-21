defmodule AshCell.CellKey do
  @moduledoc """
  Where Ash's tenant becomes a cell key, and how a cell key becomes a filename.

  These are two different jobs that used to be one implicit identity function, and
  separating them is what makes the cell boundary a choice rather than an
  assumption.

  ## The two jobs

  **Resolution** maps the value Ash carries as `tenant` to the cell that should
  serve it. By default that is the identity function: one cell per tenant, which
  is the shape this project was designed around. An application that wants a
  different cut supplies its own resolver.

  **Encoding** maps a cell key to a path-safe string, used for the local filename
  and for every object-store key. This is not cosmetic — see below.

  ## Cutting cells some other way

  Nothing in AshCell requires a cell to be a customer. The cell key is an opaque
  term used as a registry key, a filename, and an object-store prefix, so any
  partitioning the application can name is expressible:

    * **per tenant** (the default) — transactions and joins across everything one
      customer owns, blast radius of one customer
    * **per entity** — a channel, document, chat session, or agent gets its own
      serialisable single writer
    * **per tenant per window** — `"acme:2026-08"` bounds cell size permanently,
      which matters because `AshCell.Replicator` ships whole files: snapshot cost
      becomes proportional to the current window rather than to all history
    * **per workload** — `"acme:billing"` separates contention and migration
      cadence between subsystems

  Each trades something real. Anything finer than per-tenant gives up
  cross-cell transactions (`AshCell.transaction/2` refuses them rather than
  half-applying) and cross-cell queries, and multiplies the cell count that the
  deploy-migration and thundering-herd problems both scale with. Read
  `docs/spec.md` §4.6 before choosing one.

  ## Resolution takes the tenant, and deliberately not the query

  A resolver sees the tenant value and nothing else. It is tempting to let it
  inspect the query — that would let `"give me August"` route itself to the August
  cell — and it is a trap.

  `AshCell.Binder` is asked for a connection **once per statement**. A resolver
  that varied with the query could therefore send two statements of one Ash action
  to two different cells, and a transaction cannot span two cells: separate files,
  separate connections, and WAL loses cross-database atomicity even with `ATTACH`.
  That is refused rather than papered over, so a query-dependent resolver would
  turn a routing decision into a runtime transaction failure the caller cannot
  predict.

  So the application decides the cut at the point it issues the query, by putting
  it in the tenant value:

      Ash.read!(Message, tenant: "acme:2026-08")

  which is honest about the fact that a cut was chosen, and keeps one cell per
  tenant context so transactions stay sound. Reading across sibling cells is an
  explicit fan-out in application code; there is no implicit merge.

  ## Encoding must be injective, and sanitising is not

  The obvious encoding — replace awkward characters with `_` — is wrong in a way
  that does not announce itself. `"a:b"` and `"a_b"` both sanitise to `a_b`, so
  two cells share one database file and one object-store prefix. Rows cross the
  boundary the whole design exists to hold, and nothing errors.

  Interpolating unescaped is worse: a key of `"../../etc/x"` escapes the cell
  directory entirely.

  So `encode/1` is a reversible escape rather than a filter. Unreserved characters
  pass through, everything else becomes `~` plus its bytes in hex. Common keys
  stay readable, which matters for anyone who has to `ls` a cell directory during
  an incident:

      "acme"          -> "acme"
      "acme:2026-08"  -> "acme~3A2026-08"
      "../../etc/x"   -> "..~2F..~2Fetc~2Fx"

  Because `~` is itself escaped, distinct keys always encode distinctly.
  """

  @doc """
  Maps the value Ash carries as `tenant` to the key of the cell that should serve
  it.

  Must be deterministic: the same tenant has to resolve to the same cell every
  time, because `AshCell.Binder` calls this per statement and two statements of
  one action must reach one connection.
  """
  @callback resolve(tenant :: term()) :: binary()

  @default_resolver AshCell.CellKey.Identity

  @doc """
  Resolves `tenant` to a cell key using the configured resolver.

      config :ash_cell, cell_key: MyApp.CellKey

  Defaults to `AshCell.CellKey.Identity`, which is one cell per tenant.
  """
  @spec resolve(term()) :: binary()
  def resolve(tenant) do
    resolver().resolve(tenant)
  end

  @doc "The configured resolver module."
  @spec resolver() :: module()
  def resolver, do: Application.get_env(:ash_cell, :cell_key, @default_resolver)

  @doc """
  Encodes a cell key as a path-safe string, injectively.

  Raises if the key is not a non-empty binary. Resolvers are responsible for
  producing binaries: allowing atoms too would break injectivity, since `:acme`
  and `"acme"` are different cells that would encode identically.
  """
  @spec encode(binary()) :: binary()
  def encode(cell_key) when is_binary(cell_key) and byte_size(cell_key) > 0 do
    cell_key
    |> :binary.bin_to_list()
    |> Enum.map(&encode_byte/1)
    |> IO.iodata_to_binary()
  end

  def encode(other) do
    raise ArgumentError, """
    a cell key must be a non-empty binary, got: #{inspect(other)}

    A cell key becomes a filename and an object-store prefix, so it has to encode
    injectively. Atoms and strings would collide (`:acme` and "acme" are different
    cells but the same filename), so #{inspect(AshCell.CellKey)}.resolve/1 must
    return a binary.
    """
  end

  # Unreserved per RFC 3986, minus `~`, which is the escape character and so must
  # itself be escaped for the encoding to stay reversible.
  defp encode_byte(byte)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?-, ?., ?_] do
    byte
  end

  defp encode_byte(byte) do
    ["~", byte |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.upcase()]
  end

  @doc """
  Decodes a string produced by `encode/1`.

  Only used by operational tooling that has a filename or object key and wants the
  cell key back; nothing on the hot path needs it.
  """
  @spec decode(binary()) :: {:ok, binary()} | :error
  def decode(encoded) when is_binary(encoded), do: decode(encoded, [])

  defp decode(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp decode(<<"~", hi, lo, rest::binary>>, acc) do
    case Integer.parse(<<hi, lo>>, 16) do
      {byte, ""} -> decode(rest, [byte | acc])
      _ -> :error
    end
  end

  defp decode(<<"~", _::binary>>, _acc), do: :error
  defp decode(<<byte, rest::binary>>, acc), do: decode(rest, [byte | acc])
end

defmodule AshCell.CellKey.Identity do
  @moduledoc """
  One cell per tenant: the default cut, and the shape the rest of the design was
  built around.

  A tenant is used as its own cell key. Binaries pass through; atoms and integers
  are stringified for convenience, since Ash tenants are commonly one of those and
  the alternative is making every caller do it.

  That convenience is a deliberate collision: `:acme`, `"acme"` and — for an
  integer-keyed tenant — `1` and `"1"` resolve to the *same* cell. Within one
  resource the tenant is consistently one type, so in practice this only spares
  callers a `to_string/1`. If an application genuinely needs `:acme` and `"acme"`
  to be different cells, it needs its own resolver; the type cannot be recovered
  from the filename.
  """

  @behaviour AshCell.CellKey

  @impl true
  def resolve(tenant) when is_binary(tenant), do: tenant
  def resolve(tenant) when is_atom(tenant) and not is_nil(tenant), do: Atom.to_string(tenant)
  def resolve(tenant) when is_integer(tenant), do: Integer.to_string(tenant)

  def resolve(other) do
    raise ArgumentError, """
    cannot use #{inspect(other)} as a cell key.

    #{inspect(__MODULE__)} handles binaries, atoms, and integers. For anything
    else — a composite tenant, a struct, a tuple — supply a resolver that says
    how it maps to a cell:

        config :ash_cell, cell_key: MyApp.CellKey
    """
  end
end
