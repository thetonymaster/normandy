defmodule Normandy.Agents.Turn.ServerIntegrationTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Components.ToolCall

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Parameterized fake tool: name is configurable; run/1 returns {:ok, "charged"}.
  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:name, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.Turn.ServerIntegrationTest.FakeTool do
    def tool_name(t), do: t.name
    def tool_description(_), do: "fake billing tool"
    def input_schema(_), do: %{}
    def run(_t), do: {:ok, "charged"}
  end

  # Builds a BaseAgentConfig with billing tool + Ruleset policy requiring approval for "billing".
  defp integration_config(_store) do
    tools = [%FakeTool{name: "billing"}]

    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      tool_registry: Normandy.Tools.Registry.new(tools),
      behaviours: %Normandy.Behaviours.Config{
        policy:
          {Normandy.Behaviours.PolicyEngine.Ruleset,
           rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
           default_action: :allow}
      }
    }
  end

  # Counter-switched call_llm:
  #   - 1st call → one billing tool call (will be parked for approval)
  #   - every subsequent call → no-tools final response
  defp integration_handlers do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _config, _state, _req ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if n == 0 do
        %Resp{
          content: "",
          tool_calls: [%ToolCall{id: "pk1", name: "billing", input: %{}}]
        }
      else
        %Resp{content: "done", tool_calls: nil}
      end
    end

    %{Normandy.Agents.BaseAgent.non_streaming_handlers() | call_llm: call_llm}
  end

  # Poll until Native.whereis returns :none, up to ~1s in 20ms increments.
  defp wait_until_passivated(reg, session_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    case Native.whereis(reg, session_id) do
      :none ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Server did not passivate within 1s")
        else
          Process.sleep(20)
          wait_until_passivated(reg, session_id, deadline)
        end
    end
  end

  test "park → approve → resume → finalize, then passivate → rehydrate → continue" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    parent = self()

    opts = [
      session_id: "round-trip",
      config: integration_config(store),
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      idle_timeout_ms: 60,
      handlers: integration_handlers(),
      subscriber: fn name, meta -> send(parent, {:event, name, meta}) end
    ]

    # Phase 1: park → approve → finalize
    spawn(fn -> send(parent, {:result, Turn.Session.run(opts, "please charge")}) end)
    assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

    :ok = Turn.Session.approve(opts, %{"pk1" => :approve})
    assert_receive {:result, {:ok, %Resp{}}}, 2_000

    # Phase 2: let server passivate after idle timeout
    # Be resilient to the race: the server may already be gone by the time we check.
    case Native.whereis(reg, "round-trip") do
      {:ok, p} ->
        ref = Process.monitor(p)
        assert_receive {:DOWN, ^ref, _, _, :normal}, 1_000

      :none ->
        :ok
    end

    # Poll until the registry confirms passivation (async unregister).
    wait_until_passivated(reg, "round-trip")
    assert :none = Native.whereis(reg, "round-trip")

    # Phase 3: rehydrate from the store and continue the same conversation.
    assert {:ok, _} = Turn.Session.run(opts, "follow up")
  end
end
