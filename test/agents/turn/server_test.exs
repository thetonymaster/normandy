defmodule Normandy.Agents.Turn.ServerTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory

  # A response model the FSM finalizes on: no tool_calls → :completed.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Minimal config the reused BaseAgent helpers tolerate for a no-tools turn.
  # `client` is a fake the call_llm helper will hit; for the unit test we inject
  # the LLM via a stub handler set rather than a real client (see Step 3 note).
  defp base_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      tool_registry: nil
    }
  end

  test "a no-tools turn runs to :finalize and replies the final response" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    # Inject a fake LLM via the :handlers override (test seam, see Step 3).
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> %Resp{content: "hi", tool_calls: nil} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s1",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        subscriber: nil
      )

    assert {:ok, final} = Turn.Server.run(srv, "hello")
    assert %Resp{content: "hi"} = final
  end
end
