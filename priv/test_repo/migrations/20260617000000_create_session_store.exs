defmodule Normandy.TestRepo.Migrations.CreateSessionStore do
  use Ecto.Migration

  def up, do: Normandy.Behaviours.SessionStore.Postgres.Migration.up()
  def down, do: Normandy.Behaviours.SessionStore.Postgres.Migration.down()
end
