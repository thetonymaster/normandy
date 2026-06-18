defmodule Normandy.TestRepo.Migrations.AddResumePolicy do
  use Ecto.Migration

  def up, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy.up()
  def down, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy.down()
end
