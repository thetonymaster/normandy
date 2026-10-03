defmodule Normandy.TestRepo.Migrations.CreateMemoryStore do
  use Ecto.Migration

  def up, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.up()
  def down, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.down()
end
