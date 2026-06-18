defmodule Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate do
  @moduledoc "Adds the config_template column to normandy_sessions (Phase 7c)."
  use Ecto.Migration

  def up, do: alter(table(:normandy_sessions), do: add(:config_template, :binary))
  def down, do: alter(table(:normandy_sessions), do: remove(:config_template))
end
