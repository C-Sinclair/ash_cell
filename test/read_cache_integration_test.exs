defmodule AshCell.ReadCacheIntegrationTest do
  @moduledoc """
  That the cache is wired to the *data layer* rather than to a call site.

  `AshCell.ReadCacheTest` pins the ordering rules in isolation; this checks the
  claim that makes them useful — that an ordinary Ash write invalidates the cache
  without the caller doing anything, including on the paths a caller cannot wrap:
  an atomic update, a bulk write, and a transaction spanning several actions.
  """
  use ExUnit.Case, async: false

  alias AshCell.ReadCache
  alias AshCell.Test.BoundPatient

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_rc_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, max_resident: 3, migrator: &AshCell.TestSchema.run/1}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, tenant: "acme_#{System.unique_integer([:positive])}"}
  end

  # The projection under test: the whole read path, cached as one value.
  defp cached_names(tenant) do
    ReadCache.read(tenant, :names, fn -> names(tenant) end)
  end

  defp names(tenant) do
    BoundPatient
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read!()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  test "a cached projection is served from persistent_term, not the database", %{tenant: tenant} do
    BoundPatient.create!("Ada", tenant: tenant)

    assert cached_names(tenant) == ["Ada"]
    assert ReadCache.fetch(tenant, :names) == {:ok, ["Ada"]}
  end

  test "a create invalidates it, with no help from the caller", %{tenant: tenant} do
    BoundPatient.create!("Ada", tenant: tenant)
    assert cached_names(tenant) == ["Ada"]

    BoundPatient.create!("Grace", tenant: tenant)

    assert ReadCache.fetch(tenant, :names) == :miss
    assert cached_names(tenant) == ["Ada", "Grace"]
  end

  test "an atomic update invalidates it", %{tenant: tenant} do
    patient = BoundPatient.create!("Ada", tenant: tenant)
    assert cached_names(tenant) == ["Ada"]

    # Ash builds this as one UPDATE statement, so there is no changeset for a
    # caller to hook and nothing above the data layer that sees it.
    patient
    |> Ash.Changeset.for_update(:rename, %{name: "Ada L"}, tenant: tenant)
    |> Ash.update!()

    assert ReadCache.fetch(tenant, :names) == :miss
    assert cached_names(tenant) == ["Ada L"]
  end

  test "a destroy invalidates it", %{tenant: tenant} do
    patient = BoundPatient.create!("Ada", tenant: tenant)
    assert cached_names(tenant) == ["Ada"]

    Ash.destroy!(patient, tenant: tenant)

    assert ReadCache.fetch(tenant, :names) == :miss
    assert cached_names(tenant) == []
  end

  test "a bulk create invalidates it", %{tenant: tenant} do
    BoundPatient.create!("Ada", tenant: tenant)
    assert cached_names(tenant) == ["Ada"]

    Ash.bulk_create!([%{name: "Grace"}, %{name: "Edsger"}], BoundPatient, :create,
      tenant: tenant
    )

    assert ReadCache.fetch(tenant, :names) == :miss
    assert cached_names(tenant) == ["Ada", "Edsger", "Grace"]
  end

  test "a read does not invalidate it", %{tenant: tenant} do
    BoundPatient.create!("Ada", tenant: tenant)
    assert cached_names(tenant) == ["Ada"]

    _ = names(tenant)
    _ = Ash.count!(BoundPatient, tenant: tenant)

    assert ReadCache.fetch(tenant, :names) == {:ok, ["Ada"]}
  end

  test "one tenant's write leaves another tenant's projection alone", %{tenant: tenant} do
    other = tenant <> "_other"

    BoundPatient.create!("Ada", tenant: tenant)
    BoundPatient.create!("Grace", tenant: other)

    assert cached_names(tenant) == ["Ada"]
    assert cached_names(other) == ["Grace"]

    BoundPatient.create!("Edsger", tenant: tenant)

    assert ReadCache.fetch(tenant, :names) == :miss
    assert ReadCache.fetch(other, :names) == {:ok, ["Grace"]}
  end

  test "a transaction invalidates once it commits, not before", %{tenant: tenant} do
    BoundPatient.create!("Ada", tenant: tenant)
    assert cached_names(tenant) == ["Ada"]

    {:ok, :done} =
      AshCell.transaction(tenant, fn ->
        BoundPatient.create!("Grace", tenant: tenant)

        # Mid-transaction the cache is already cold, and a projection built from
        # the uncommitted state cannot be published into it.
        epoch = ReadCache.epoch(tenant)
        assert ReadCache.publish(tenant, :names, ["Ada", "Grace"], epoch) == :stale

        :done
      end)

    assert ReadCache.fetch(tenant, :names) == :miss
    assert cached_names(tenant) == ["Ada", "Grace"]
  end

  test "a rolled back transaction leaves the cache cold, not wrong", %{tenant: tenant} do
    BoundPatient.create!("Ada", tenant: tenant)
    assert cached_names(tenant) == ["Ada"]

    {:error, :nope} =
      AshCell.transaction(tenant, fn ->
        BoundPatient.create!("Grace", tenant: tenant)
        AshCell.rollback(:nope)
      end)

    assert ReadCache.fetch(tenant, :names) == :miss
    assert cached_names(tenant) == ["Ada"]
  end
end
