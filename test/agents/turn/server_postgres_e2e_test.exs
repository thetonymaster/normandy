defmodule Normandy.Agents.Turn.ServerPostgresE2ETest do
  @moduledoc "GAP: durable :server lifecycle (persist → passivate → rehydrate) against real Postgres."
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.Postgres
  alias Normandy.Behaviours.SessionRegistry.Native

  # Output struct the fake LLM returns; mirrors the Turn.Server test idiom.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo)
    # Supervised Turn.Server runs in its own process and must see the same
    # sandboxed connection — shared mode + async: false.
    Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  defp server_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      tool_registry: nil
    }
  end

  defp final_handlers(text \\ "ok") do
    %{BaseAgent.non_streaming_handlers() | call_llm: fn _c, _s, _r -> %Resp{content: text} end}
  end

  test "a turn persists to Postgres and rehydrates with no data loss" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    reg = Native.new()
    sid = "pg-e2e-#{System.unique_integer([:positive])}"

    opts = [
      session_id: sid,
      config: server_config(),
      store: {Postgres, Postgres.new()},
      registry: {Native, reg},
      supervisor: sup,
      idle_timeout_ms: 60,
      handlers: final_handlers("first")
    ]

    # Turn 1: runs and persists to Postgres.
    assert {:ok, %Resp{content: "first"}} = Turn.Session.run(opts, "hello")

    # DURABILITY INVARIANT: the user input is in Postgres after the turn.
    assert {:ok, entries} = Postgres.history(Postgres.new(), sid)
    assert entries != [], "expected the turn to persist entries to Postgres; got none"
    first_count = length(entries)

    # Let the server passivate (idle timeout), then rehydrate via a second run.
    Process.sleep(150)
    assert :none = Native.whereis(reg, sid)

    assert {:ok, %Resp{content: "second"}} =
             Turn.Session.run(Keyword.put(opts, :handlers, final_handlers("second")), "again")

    # NO-LOSS INVARIANT: history grew across passivation; turn-1 entries survived.
    assert {:ok, entries2} = Postgres.history(Postgres.new(), sid)

    assert length(entries2) > first_count,
           "rehydrated history did not grow; passivation may have dropped persisted state"
  end
end
