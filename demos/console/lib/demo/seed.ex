defmodule Demo.Seed do
  @moduledoc """
  Builds the demo fleet: clinics in the global Postgres, clinical data in each
  clinic's own cell.

  Also seeds an identically-shaped dataset into Postgres so the console can run
  the *same* Ash query against both data layers and compare honestly. That
  comparison is only worth showing if the Postgres side is a fair opponent, so it
  gets the same rows and proper indexes.
  """

  alias Demo.Clinical.{Encounter, Observation, Patient}
  alias Demo.Global.Clinic

  @clinics [
    {"mercy_general", "Mercy General", "us-west", "enterprise"},
    {"st_agnes", "St Agnes Community", "us-east", "growth"},
    {"riverside", "Riverside Family Practice", "us-west", "growth"},
    {"north_shore", "North Shore Paediatrics", "eu-west", "starter"},
    {"lakeside", "Lakeside Health", "us-central", "enterprise"},
    {"harbour_view", "Harbour View Clinic", "ap-southeast", "starter"}
  ]

  @reasons ["Annual review", "Follow-up", "Acute visit", "Screening", "Referral"]
  @codes ["BP_SYSTOLIC", "HR", "BMI", "HBA1C", "TEMP"]

  def clinics, do: @clinics

  def run(opts \\ []) do
    patients_per_clinic = Keyword.get(opts, :patients, 150)

    for {id, name, region, plan} <- @clinics do
      upsert_clinic(id, name, region, plan)
      seed_cell(id, patients_per_clinic)
    end

    seed_postgres_comparison(patients_per_clinic)
    :ok
  end

  defp upsert_clinic(id, name, region, plan) do
    case Ash.get(Clinic, id) do
      {:ok, _existing} -> :ok
      _ -> Clinic.create!(%{id: id, name: name, region: region, plan: plan})
    end
  end

  defp seed_cell(clinic_id, count) do
    AshCell.with_tenant(clinic_id, fn ->
      existing = Patient |> Ash.Query.set_tenant(clinic_id) |> Ash.read!() |> length()

      if existing == 0 do
        for i <- 1..count do
          patient =
            Patient.create!(
              %{
                name: person_name(clinic_id, i),
                mrn: "MRN-#{String.upcase(String.slice(clinic_id, 0, 3))}-#{i}",
                birth_year: 1940 + rem(i * 7, 70),
                risk_score: rem(i * 13, 100)
              },
              tenant: clinic_id
            )

          for e <- 1..3 do
            encounter =
              Encounter.create!(
                %{
                  patient_id: patient.id,
                  reason: Enum.at(@reasons, rem(i + e, length(@reasons))),
                  occurred_on: Date.add(~D[2026-01-01], rem(i * e, 200))
                },
                tenant: clinic_id
              )

            for o <- 1..4 do
              Observation.create!(
                %{
                  encounter_id: encounter.id,
                  code: Enum.at(@codes, rem(o + e, length(@codes))),
                  value: 60 + rem(i * o * 3, 120)
                },
                tenant: clinic_id
              )
            end
          end
        end
      end
    end)
  end

  # The Postgres comparison set: same shape, same volume, indexed the way anyone
  # would index it in production. A rigged comparison would prove nothing.
  defp seed_postgres_comparison(count) do
    Demo.Repo.query!("""
    CREATE TABLE IF NOT EXISTS pg_patients (
      id uuid PRIMARY KEY,
      clinic_id text NOT NULL,
      name text NOT NULL,
      mrn text,
      birth_year integer,
      risk_score integer
    )
    """)

    Demo.Repo.query!("""
    CREATE TABLE IF NOT EXISTS pg_encounters (
      id uuid PRIMARY KEY,
      clinic_id text NOT NULL,
      patient_id uuid NOT NULL,
      reason text,
      occurred_on date
    )
    """)

    Demo.Repo.query!("""
    CREATE TABLE IF NOT EXISTS pg_observations (
      id uuid PRIMARY KEY,
      clinic_id text NOT NULL,
      encounter_id uuid NOT NULL,
      code text,
      value integer
    )
    """)

    for {table, cols} <- [
          {"pg_patients", "clinic_id"},
          {"pg_encounters", "clinic_id, patient_id"},
          {"pg_observations", "clinic_id, encounter_id"}
        ] do
      Demo.Repo.query!("CREATE INDEX IF NOT EXISTS #{table}_idx ON #{table} (#{cols})")
    end

    %{rows: [[existing]]} = Demo.Repo.query!("SELECT count(*) FROM pg_patients")

    if existing == 0 do
      for {clinic_id, _, _, _} <- @clinics, i <- 1..count do
        patient_id = Ecto.UUID.generate()

        Demo.Repo.query!(
          "INSERT INTO pg_patients (id, clinic_id, name, mrn, birth_year, risk_score) VALUES ($1,$2,$3,$4,$5,$6)",
          [
            Ecto.UUID.dump!(patient_id),
            clinic_id,
            person_name(clinic_id, i),
            "MRN-#{i}",
            1940 + rem(i * 7, 70),
            rem(i * 13, 100)
          ]
        )

        for e <- 1..3 do
          encounter_id = Ecto.UUID.generate()

          Demo.Repo.query!(
            "INSERT INTO pg_encounters (id, clinic_id, patient_id, reason, occurred_on) VALUES ($1,$2,$3,$4,$5)",
            [
              Ecto.UUID.dump!(encounter_id),
              clinic_id,
              Ecto.UUID.dump!(patient_id),
              Enum.at(@reasons, rem(i + e, length(@reasons))),
              Date.add(~D[2026-01-01], rem(i * e, 200))
            ]
          )

          for o <- 1..4 do
            Demo.Repo.query!(
              "INSERT INTO pg_observations (id, clinic_id, encounter_id, code, value) VALUES ($1,$2,$3,$4,$5)",
              [
                Ecto.UUID.dump!(Ecto.UUID.generate()),
                clinic_id,
                Ecto.UUID.dump!(encounter_id),
                Enum.at(@codes, rem(o + e, length(@codes))),
                60 + rem(i * o * 3, 120)
              ]
            )
          end
        end
      end

      Demo.Repo.query!("ANALYZE pg_patients")
      Demo.Repo.query!("ANALYZE pg_encounters")
      Demo.Repo.query!("ANALYZE pg_observations")
    end
  end

  @first ~w(Ada Grace Alan Edsger Barbara Donald Ken Dennis Margaret Linus Katherine Radia)
  @last ~w(Lovelace Hopper Turing Dijkstra Liskov Knuth Thompson Ritchie Hamilton Torvalds Johnson Perlman)

  defp person_name(clinic_id, i) do
    seed = :erlang.phash2({clinic_id, i})
    first = Enum.at(@first, rem(seed, length(@first)))
    last = Enum.at(@last, rem(div(seed, 13), length(@last)))
    "#{first} #{last} #{i}"
  end
end
