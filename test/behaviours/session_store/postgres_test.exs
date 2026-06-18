defmodule Normandy.Behaviours.SessionStore.PostgresTest do
  @moduledoc """
  Run with: `mix test test/behaviours/session_store/postgres_test.exs --include postgres`
  Requires a reachable Postgres (see config/test.exs).
  """
  use ExUnit.Case, async: true
  @moduletag :postgres

  alias Normandy.Behaviours.SessionStore.Postgres

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo)
  end

  test "new/0 returns the configured repo handle and the behaviour is implemented" do
    assert Postgres.new() == Normandy.TestRepo
    behaviours = Postgres.module_info(:attributes)[:behaviour] || []
    assert Normandy.Behaviours.SessionStore in behaviours
  end
end
