if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate do
    @moduledoc "Adds the config_template column to normandy_sessions (Phase 7c)."
    use Ecto.Migration

    @doc """
    Adds the nullable `config_template` column (binary) to `normandy_sessions`, where
    `save_config_template/3` stores the template. Run it after `Migration`.
    """
    def up, do: alter(table(:normandy_sessions), do: add(:config_template, :binary))
    @doc "Removes the `config_template` column, and with it every saved template."
    def down, do: alter(table(:normandy_sessions), do: remove(:config_template))
  end
end
