defmodule Magpie.Repo.Migrations.CreateLibrary do
  use Ecto.Migration

  def change do
    # One row per distinct sound; id = SHA-256 (hex) of its f32le PCM.
    create table(:samples, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :source, :string, null: false
      add :tags, {:array, :string}, null: false, default: []
      add :rate, :integer, null: false
      add :channels, :integer, null: false
      add :frames, :integer, null: false
      add :peaks, :binary
      timestamps(type: :utc_datetime_usec)
    end

    create index(:samples, [:source])

    # A saved kit, as its magpie.kit/1 JSON; sample_ids for "is this sample in use".
    create table(:kits, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :json, :text, null: false
      add :sample_ids, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime_usec)
    end
  end
end
