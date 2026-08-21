defmodule AshCell.CellKeyTest do
  @moduledoc """
  The encoding is the part worth testing hard.

  A cell key becomes a filename and an object-store prefix, so a collision is not
  a cosmetic bug: two cells share one database and rows cross the isolation
  boundary the whole design exists to hold, with nothing raising. So the property
  under test is injectivity, not readability.
  """
  # Not async: the resolver lives in application env, so these tests mutate global
  # configuration. Concurrent with any test that binds a cell, the NotABinary
  # resolver below would make an unrelated bind raise.
  use ExUnit.Case, async: false

  alias AshCell.CellKey

  defmodule Windowed do
    @moduledoc false
    @behaviour AshCell.CellKey

    @impl true
    def resolve({tenant, %Date{} = date}) do
      "#{tenant}:#{date.year}-#{String.pad_leading(to_string(date.month), 2, "0")}"
    end

    def resolve(tenant), do: to_string(tenant)
  end

  defmodule NotABinary do
    @moduledoc false
    @behaviour AshCell.CellKey

    @impl true
    def resolve(_tenant), do: :not_a_binary
  end

  describe "encoding" do
    test "an ordinary key passes through unchanged" do
      # Readability is not the property under test, but it is the reason for
      # escaping rather than hashing: an operator listing a cell directory during
      # an incident should recognise what they are looking at.
      assert CellKey.encode("acme") == "acme"
      assert CellKey.encode("acme-corp_1.2") == "acme-corp_1.2"
    end

    test "a composite key escapes its separator but stays legible" do
      assert CellKey.encode("acme:2026-08") == "acme~3A2026-08"
    end

    test "path traversal cannot escape the cell directory" do
      # Before this existed, Manager interpolated the key straight into
      # Path.join/2, so this key wrote outside the configured directory.
      encoded = CellKey.encode("../../etc/passwd")

      refute String.contains?(encoded, "/")
      assert Path.join("/cells", encoded <> ".db") == "/cells/..~2F..~2Fetc~2Fpasswd.db"
    end

    test "the escape character is itself escaped, which is what makes it reversible" do
      # Without this, "a~3Ab" and "a:b" would encode identically.
      assert CellKey.encode("a~3Ab") == "a~7E3Ab"
      refute CellKey.encode("a~3Ab") == CellKey.encode("a:b")
    end

    test "sanitising would have collided here, and escaping does not" do
      # The specific bug this design avoids: replacing awkward bytes with "_"
      # maps both of these to "a_b".
      assert CellKey.encode("a:b") != CellKey.encode("a_b")
      assert CellKey.encode("a/b") != CellKey.encode("a:b")
    end

    test "distinct keys encode distinctly across an adversarial set" do
      keys = [
        "a",
        "a:b",
        "a_b",
        "a/b",
        "a~b",
        "a~2Fb",
        "A",
        "a.b",
        "a b",
        "..",
        "a\\b",
        "a\0b",
        "ünicode",
        "🙂",
        String.duplicate("a", 200)
      ]

      encoded = Enum.map(keys, &CellKey.encode/1)

      assert length(Enum.uniq(encoded)) == length(keys)
    end

    test "encoding round-trips" do
      for key <- ["acme", "acme:2026-08", "a~b", "../x", "ünicode", "🙂", "a\0b"] do
        assert {:ok, ^key} = CellKey.decode(CellKey.encode(key))
      end
    end

    test "decoding rejects a malformed escape rather than guessing" do
      assert :error = CellKey.decode("a~ZZb")
      assert :error = CellKey.decode("a~2")
      assert :error = CellKey.decode("a~")
    end

    test "an empty or non-binary key is refused, not coerced" do
      # Coercing here would produce a shared filename for unrelated keys.
      assert_raise ArgumentError, fn -> CellKey.encode("") end
      assert_raise ArgumentError, fn -> CellKey.encode(:acme) end
      assert_raise ArgumentError, fn -> CellKey.encode({"acme", 1}) end
      assert_raise ArgumentError, fn -> CellKey.encode(nil) end
    end
  end

  describe "the default resolver" do
    test "is one cell per tenant" do
      assert CellKey.resolve("acme") == "acme"
    end

    test "stringifies atoms and integers, and this is a documented collision" do
      assert CellKey.resolve(:acme) == "acme"
      assert CellKey.resolve(1) == "1"
      assert CellKey.resolve(:acme) == CellKey.resolve("acme")
    end

    test "refuses a tenant it cannot map, naming the way out" do
      error = assert_raise ArgumentError, fn -> CellKey.resolve({"acme", 1}) end

      assert error.message =~ "supply a resolver"
    end
  end

  describe "a custom resolver" do
    setup do
      Application.put_env(:ash_cell, :cell_key, Windowed)
      on_exit(fn -> Application.delete_env(:ash_cell, :cell_key) end)
    end

    test "can cut cells by tenant and time window" do
      assert CellKey.resolve({"acme", ~D[2026-08-21]}) == "acme:2026-08"
      assert CellKey.resolve({"acme", ~D[2026-09-01]}) == "acme:2026-09"
    end

    test "resolves the whole of a window to one cell, so transactions stay sound" do
      # Two statements in one action must reach one connection. That only holds
      # because resolution sees the tenant and not the query.
      first = CellKey.resolve({"acme", ~D[2026-08-01]})
      last = CellKey.resolve({"acme", ~D[2026-08-31]})

      assert first == last
    end

    test "its output still has to encode safely" do
      assert CellKey.resolve({"acme", ~D[2026-08-21]}) |> CellKey.encode() == "acme~3A2026-08"
    end
  end

  describe "a resolver that returns a non-binary" do
    setup do
      Application.put_env(:ash_cell, :cell_key, NotABinary)
      on_exit(fn -> Application.delete_env(:ash_cell, :cell_key) end)
    end

    test "fails at encode time rather than producing a colliding filename" do
      assert_raise ArgumentError, fn -> "acme" |> CellKey.resolve() |> CellKey.encode() end
    end
  end
end
