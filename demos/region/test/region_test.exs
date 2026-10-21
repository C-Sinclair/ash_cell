defmodule RegionTest do
  @moduledoc """
  The design doc's claims 1 to 4: each cell's durable state lands in its own region's
  bucket, the scope alone builds the cell key, a project outside its organisation's
  allowed regions is refused with nothing written, and an unknown region raises.
  """
  use Region.RegionCase, async: false

  alias Region.Scope

  @moduletag :capture_log

  defp org(home_region, allowed_regions) do
    {:ok, org} = Region.create_org(unique_name("org"), home_region, allowed_regions)
    %Scope{actor: :tester, org: org}
  end

  describe "the scope builds the cell key" do
    test "an organisation's key is its home region and id" do
      scope = org("eu", ["eu", "us"])
      assert Region.cell_key(scope) == "eu:#{scope.org.id}"
    end

    test "a project in its organisation's home region shares the organisation's cell" do
      scope = org("eu", ["eu", "us"])
      project = %{id: Ash.UUID.generate(), region: "eu"}
      assert Region.cell_key(%{scope | project: project}) == "eu:#{scope.org.id}"
    end

    test "a project in another region gets its own cell, keyed by that region" do
      scope = org("eu", ["eu", "us"])
      project = %{id: Ash.UUID.generate(), region: "us"}

      assert Region.cell_key(%{scope | project: project}) ==
               "us:#{scope.org.id}:#{project.id}"
    end
  end

  describe "bucket placement" do
    test "an organisation's cell and a project's own cell each land only in their region's bucket" do
      scope = org("eu", ["eu", "us"])
      org_key = Region.cell_key(scope)
      {:ok, _} = AshCell.claim(org_key)

      {:ok, home_project} = Region.create_project(scope, %{name: "home"})
      {:ok, _} = Region.create_task(Region.project_scope(scope, home_project), %{title: "a"})

      {:ok, us_project} = Region.create_project(scope, %{name: "abroad", region: "us"})
      us_scope = Region.project_scope(scope, us_project)
      project_key = Region.cell_key(us_scope)
      assert project_key == "us:#{scope.org.id}:#{us_project.id}"
      {:ok, _} = AshCell.claim(project_key)
      {:ok, _} = Region.create_task(us_scope, %{title: "b"})

      {:ok, _} = ship(org_key)
      {:ok, _} = ship(project_key)

      assert %{snapshots: 1, lease?: true, generation?: true} = held("eu", org_key)
      assert %{snapshots: 0, lease?: false, generation?: false} = held("us", org_key)
      assert %{snapshots: 1, lease?: true, generation?: true} = held("us", project_key)
      assert %{snapshots: 0, lease?: false, generation?: false} = held("eu", project_key)

      assert {:ok, [%{name: "home"}]} = Region.projects(scope)
      assert {:ok, [%{name: "abroad", region: "us"}]} = Region.projects(us_scope)
      assert {:ok, [%{title: "b"}]} = Region.tasks(us_scope)
    end
  end

  describe "a project outside its organisation's allowed regions" do
    test "is refused, and nothing is written to either bucket or the cell directory" do
      scope = org("eu", ["eu"])

      assert {:error, %Ash.Error.Invalid{} = error} =
               Region.create_project(scope, %{name: "stray", region: "us"})

      assert Exception.message(error) =~ "allowed regions"

      for region <- ["eu", "us"], prefix <- ["eu:#{scope.org.id}", "us:#{scope.org.id}"] do
        assert objects_under(region, prefix) == []
      end

      cell_dir = Application.fetch_env!(:ash_cell, :dir)
      encoded_org = AshCell.CellKey.encode(scope.org.id)

      refute cell_dir |> File.ls!() |> Enum.any?(&String.contains?(&1, encoded_org))
    end
  end

  describe "an unknown region" do
    test "raises at claim instead of falling back to a default bucket" do
      assert_raise ArgumentError, ~r/no bucket for region "ap"/, fn ->
        AshCell.claim("ap:" <> unique_name("org"))
      end
    end

    test "fails the first statement of an organisation whose home region is unknown" do
      {:ok, org} = Region.create_org(unique_name("org"), "ap", ["ap"])

      manager = Process.whereis(AshCell.Manager)

      error =
        assert_raise Ash.Error.Unknown, fn ->
          Region.create_project(%Scope{actor: :tester, org: org}, %{name: "x"})
        end

      assert Exception.message(error) =~ ~s(no bucket for region "ap")
      assert Process.whereis(AshCell.Manager) == manager

      for region <- ["eu", "us"] do
        assert objects_under(region, "ap:#{org.id}") == []
      end
    end
  end
end
