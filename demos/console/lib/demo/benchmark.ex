defmodule Demo.Benchmark do
  @moduledoc """
  The same workload against both data layers, timed.

  The comparison is only worth showing if the Postgres side is a fair opponent, so
  it gets identical data, proper indexes, a warm connection pool, and the query a
  competent engineer would actually write. If AshCell only wins against a
  handicapped Postgres, that is a finding, not a demo.

  The honest headline is **N+1 immunity** rather than raw point-read latency. A
  deep relationship load is where colocating compute with storage stops being a
  micro-optimisation: the cell does the whole graph without a network hop, and
  Postgres cannot, however well indexed it is.
  """

  require Ash.Query

  alias Demo.Clinical.Patient

  @doc """
  Loads every patient in a clinic with their encounters and each encounter's
  observations — three levels, no aggregates (AshSqlite has none).
  """
  def cell_deep_load(clinic_id) do
    time(fn ->
      AshCell.with_tenant(clinic_id, fn ->
        Patient
        |> Ash.Query.set_tenant(clinic_id)
        |> Ash.Query.load(encounters: [:observations])
        |> Ash.read!()
      end)
    end)
  end

  @doc """
  The same graph from the shared Postgres, through Ash, so both sides pay the
  identical framework cost and the only variable is the data layer.
  """
  def postgres_deep_load(clinic_id) do
    time(fn ->
      require Ash.Query

      Demo.Comparison.PgPatient
      |> Ash.Query.filter(clinic_id == ^clinic_id)
      |> Ash.Query.load(encounters: [:observations])
      |> Ash.read!()
    end)
  end

  @doc "Hand-written SQL with no framework overhead, as a floor for the comparison."
  def postgres_raw_deep_load(clinic_id) do
    time(fn ->
      %{rows: patients} =
        Demo.Repo.query!(
          "SELECT id, name, mrn, birth_year, risk_score FROM pg_patients WHERE clinic_id = $1",
          [clinic_id]
        )

      %{rows: encounters} =
        Demo.Repo.query!(
          "SELECT id, patient_id, reason, occurred_on FROM pg_encounters WHERE clinic_id = $1",
          [clinic_id]
        )

      %{rows: observations} =
        Demo.Repo.query!(
          "SELECT id, encounter_id, code, value FROM pg_observations WHERE clinic_id = $1",
          [clinic_id]
        )

      obs_by_encounter = Enum.group_by(observations, &Enum.at(&1, 1))
      enc_by_patient = Enum.group_by(encounters, &Enum.at(&1, 1))

      Enum.map(patients, fn patient ->
        patient_encounters =
          enc_by_patient
          |> Map.get(Enum.at(patient, 0), [])
          |> Enum.map(fn encounter ->
            {encounter, Map.get(obs_by_encounter, Enum.at(encounter, 0), [])}
          end)

        {patient, patient_encounters}
      end)
    end)
  end

  @doc "A single point read, for the latency figure people ask about."
  def cell_point_read(clinic_id) do
    time(fn ->
      AshCell.with_tenant(clinic_id, fn ->
        Patient
        |> Ash.Query.set_tenant(clinic_id)
        |> Ash.Query.limit(1)
        |> Ash.read!()
      end)
    end)
  end

  def postgres_point_read(clinic_id) do
    time(fn ->
      Demo.Repo.query!("SELECT id, name FROM pg_patients WHERE clinic_id = $1 LIMIT 1", [
        clinic_id
      ])
    end)
  end

  @doc """
  Writes `count` rows and reports throughput.

  This is a local-fsync number. It does **not** include shipping to the object
  store, which in a durable configuration adds a round trip per commit. Quoting
  this figure as if it were the durable write latency would be dishonest.
  """
  def write_storm(clinic_id, count) do
    {micros, _} =
      time(fn ->
        AshCell.with_tenant(clinic_id, fn ->
          for i <- 1..count do
            Patient.create!(
              %{name: "Storm Patient #{i}", mrn: "STORM-#{i}", birth_year: 1980, risk_score: 1},
              tenant: clinic_id
            )
          end
        end)
      end)

    %{
      count: count,
      micros: micros,
      per_write_micros: div(micros, max(count, 1)),
      per_second: round(count / max(micros / 1_000_000, 0.000001))
    }
  end

  def count_rows(clinic_id) do
    AshCell.with_tenant(clinic_id, fn ->
      {:ok, pid} = AshCell.Manager.ensure_started(clinic_id)
      repo_pid = AshCell.Cell.repo_pid(pid)

      for table <- ~w(patients encounters observations), into: %{} do
        %{rows: [[count]]} =
          Ecto.Adapters.SQL.query!(repo_pid, "SELECT count(*) FROM #{table}", [])

        {table, count}
      end
    end)
  end

  defp time(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - started, result}
  end
end
