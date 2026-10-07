if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Normandy.Behaviours.SessionStore.Postgres.MigrationAddInflight do
    @moduledoc """
    Adds Normandy 2.0's in-flight index to `normandy_sessions`: the `inflight` column
    `SessionStore.Postgres.save_turn_state/4` writes with the turn state, a partial index
    over the rows where it is true (`list_resumable/1`), and an index on `head_id`
    (`delete_session/2` checks which entries another session still uses).

    Call it from a host migration after the other `Postgres.Migration*` modules, and run
    it before 2.0 serves traffic: 2.0 reads and writes the column. The column has a
    default, so running it while 1.x nodes still serve is safe. Existing rows start with
    `inflight = false`: a session whose turn was in flight at the upgrade is not resumed
    by `ResumeReaper` until its next turn-state save (see MIGRATING-2.0 §40, "drain eager
    sessions before upgrading").
    """
    use Ecto.Migration

    def up do
      alter table(:normandy_sessions) do
        add(:inflight, :boolean, null: false, default: false)
      end

      create(
        index(:normandy_sessions, [:session_id],
          name: :normandy_sessions_inflight_index,
          where: "inflight = true"
        )
      )

      create(index(:normandy_sessions, [:head_id]))
    end

    def down do
      drop(index(:normandy_sessions, [:head_id]))
      drop(index(:normandy_sessions, [:session_id], name: :normandy_sessions_inflight_index))

      alter table(:normandy_sessions) do
        remove(:inflight)
      end
    end
  end
end
