defmodule Normandy.Behaviours.SessionStore.Postgres.Migration do
  @moduledoc """
  Migration for the Postgres `SessionStore`. Call from a host migration:

      defmodule MyApp.Repo.Migrations.AddNormandySessions do
        use Ecto.Migration
        def up, do: Normandy.Behaviours.SessionStore.Postgres.Migration.up()
        def down, do: Normandy.Behaviours.SessionStore.Postgres.Migration.down()
      end
  """
  use Ecto.Migration

  def up do
    create table(:normandy_session_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:parent_id, :binary_id)
      add(:turn_id, :text)
      add(:role, :text)
      add(:content, :binary)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:normandy_session_entries, [:parent_id]))

    create table(:normandy_sessions, primary_key: false) do
      add(:session_id, :text, primary_key: true)
      add(:head_id, :binary_id)
      add(:current_turn_id, :text)
      add(:turn_state, :binary)
      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    drop(table(:normandy_sessions))
    drop(table(:normandy_session_entries))
  end
end
