defmodule Normandy.TestRepo.Migrations.AddConfigTemplate do
  use Ecto.Migration
  def up, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate.up()
  def down, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate.down()
end
