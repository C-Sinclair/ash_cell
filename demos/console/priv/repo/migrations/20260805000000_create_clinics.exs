defmodule Demo.Repo.Migrations.CreateClinics do
  use Ecto.Migration

  def change do
    create table(:clinics, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :region, :text
      add :plan, :text
    end
  end
end
