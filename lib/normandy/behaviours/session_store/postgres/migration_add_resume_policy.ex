if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Normandy.Behaviours.SessionStore.Postgres.MigrationAddResumePolicy do
    @moduledoc """
    Adds the queryable `resume_policy` column to `normandy_sessions` (Phase 7d
    resume reaper). Lets `SessionStore.Postgres.list_resumable/1` filter eager
    sessions without decoding the opaque `config_template` blob. Call from a host
    migration alongside the other `Postgres.Migration*` modules.
    """
    use Ecto.Migration

    @doc """
    Adds the nullable `resume_policy` column (text) to `normandy_sessions`, which
    `save_config_template/3` fills from the template's `resume_policy`. Run it after
    `Migration`.
    """
    def up, do: alter(table(:normandy_sessions), do: add(:resume_policy, :text))
    @doc "Removes the `resume_policy` column."
    def down, do: alter(table(:normandy_sessions), do: remove(:resume_policy))
  end
end
