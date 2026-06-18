defmodule Normandy.Behaviours.SessionStore.Postgres.Schemas do
  @moduledoc false

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    @foreign_key_type :binary_id
    schema "normandy_session_entries" do
      field(:parent_id, :binary_id)
      field(:turn_id, :string)
      field(:role, :string)
      field(:content, :binary)
      field(:inserted_at, :utc_datetime_usec)
    end
  end

  defmodule Session do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:session_id, :string, autogenerate: false}
    @foreign_key_type :binary_id
    schema "normandy_sessions" do
      field(:head_id, :binary_id)
      field(:current_turn_id, :string)
      field(:turn_state, :binary)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
