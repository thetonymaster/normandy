if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Normandy.Behaviours.MemoryStore.Postgres.Migration do
    @moduledoc """
    Migration for the Postgres `MemoryStore`. Call from a host migration:

        defmodule MyApp.Repo.Migrations.AddNormandyMemory do
          use Ecto.Migration
          def up, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.up()
          def down, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.down()
        end
    """
    use Ecto.Migration

    def up do
      create table(:normandy_memory_documents, primary_key: false) do
        add(:namespace, :text, primary_key: true)
        add(:path, :text, primary_key: true)
        add(:content, :text, null: false)
        add(:version, :integer, null: false)
        add(:updated_at, :utc_datetime_usec, null: false)
      end
    end

    def down, do: drop(table(:normandy_memory_documents))
  end
end
