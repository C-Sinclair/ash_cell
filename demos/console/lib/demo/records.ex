defmodule Demo.Records do
  @moduledoc """
  Ordinary CRUD against a clinic's cell.

  This is the part of the demo that makes the rest legible. The panels either
  side of it show hexdumps, benchmarks, and object keys — evidence, but abstract.
  Typing a patient's name into one clinic and watching it appear in that clinic's
  file and nowhere else is the same claim, made concretely.

  Every function takes a tenant and passes it, and that is the whole of it. There
  is no ambient tenant and no "current clinic" global: the caller says which clinic
  it means, every time. Nothing here binds a database — `AshCell.Resource` is on
  these resources, so each action binds its own cell and releases it.

  Note what is absent from the queries — no `clinic_id`, no filter, no scope. The
  clinic is the database.
  """

  require Ash.Query

  alias Demo.Clinical.Patient

  @doc "Patients in a clinic, newest first."
  def list_patients(tenant, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    Patient
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(tenant: tenant)
  end

  @doc "Total patients in a clinic, so the list can say what it is showing a slice of."
  def count_patients(tenant) do
    Ash.count!(Patient, tenant: tenant)
  end

  def get_patient(tenant, id) do
    Patient.get_by_id(id, tenant: tenant)
  end

  def create_patient(tenant, attrs) do
    Patient.create(normalise(attrs), tenant: tenant)
  end

  def update_patient(tenant, %Patient{} = patient, attrs) do
    Patient.update(patient, normalise(attrs), tenant: tenant)
  end

  def delete_patient(tenant, %Patient{} = patient) do
    Patient.destroy(patient, tenant: tenant)
  end

  @doc """
  Looks for a name across every clinic, one cell at a time.

  Deliberately clumsy, and the clumsiness is the point. There is no query that
  spans cells, so "search all clinics" is a fan-out that opens each database in
  turn. That is the real cost of this architecture, and the demo should show it
  rather than hide it behind a panel that only ever queries one tenant.
  """
  def search_everywhere(term) do
    for clinic <- Ash.read!(Demo.Global.Clinic) do
      matches =
        Patient
        |> Ash.Query.filter(contains(name, ^term))
        |> Ash.read!(tenant: clinic.id)

      %{clinic: clinic.name, tenant: clinic.id, count: length(matches), matches: matches}
    end
  end

  # Form params arrive as strings; an empty box means "not given" rather than a
  # birth year of zero.
  defp normalise(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(~w(name mrn birth_year risk_score))
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> cast_integer("birth_year")
    |> cast_integer("risk_score")
  end

  defp cast_integer(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> Map.put(attrs, key, int)
          :error -> Map.delete(attrs, key)
        end

      _ ->
        attrs
    end
  end
end
