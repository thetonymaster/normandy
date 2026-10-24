defmodule Normandy.TestRepo.Migrations.AddInflight do
  use Ecto.Migration

  def up, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight.up()
  def down, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight.down()
end
