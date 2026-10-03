defmodule NormandyTest.Telemetry.MetadataTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, ToolCallResponse}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, ToolCall}
  alias Normandy.Telemetry.Metadata
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  defmodule BlockAll do
    @behaviour Normandy.Guardrails.Guard

    @impl true
    def check(_value, _opts),
      do: {:error, [%{guard: __MODULE__, path: [], message: "no", constraint: :block_all}]}
  end

  defmodule ToolClient do
    use Normandy.Schema

    schema do
      field(:final_response, :string, default: "done")
    end

    defimpl Normandy.Agents.Model do
      def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model),
        do: response_model

      def converse(config, _model, _temperature, _max_tokens, messages, _response_model, _opts) do
        if Enum.any?(messages, &(&1.role == "tool")) do
          %ToolCallResponse{content: config.final_response, tool_calls: []}
        else
          %ToolCallResponse{
            content: nil,
            tool_calls: [
              %ToolCall{id: "call_1", name: "calculator", input: %{operation: "add", a: 1, b: 2}}
            ]
          }
        end
      end
    end
  end

  defp attach(events) do
    parent = self()
    id = "metadata-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      events,
      fn event, _m, meta, _ -> send(parent, {:span, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp tool_agent(extra) do
    name = "metadata-agent-#{System.unique_integer([:positive])}"

    config =
      Map.merge(
        %{
          name: name,
          client: %ToolClient{},
          model: "test-model",
          tool_registry: Registry.new([%Calculator{operation: "add", a: 0, b: 0}]),
          max_tool_iterations: 5
        },
        extra
      )

    {name, BaseAgent.init(config)}
  end

  describe "Metadata.run/2 and ids/1" do
    test "run/2 omits keys with no value" do
      {name, agent} = tool_agent(%{})

      assert Metadata.run(agent) == %{model: "test-model", agent_name: name}
    end

    test "run/2 carries the session as conversation id, and the given turn id" do
      {_, agent} = tool_agent(%{session_id: "sess-1"})

      assert %{session_id: "sess-1", conversation_id: "sess-1", turn_id: "t1"} =
               Metadata.run(agent, turn_id: "t1")
    end

    test "ids/1 reads the memory's current turn id" do
      {_, agent} = tool_agent(%{session_id: "sess-2"})
      memory = AgentMemory.initialize_turn(agent.memory)
      turn_id = AgentMemory.get_current_turn_id(memory)

      assert Metadata.ids(%{agent | memory: memory}) ==
               %{turn_id: turn_id, session_id: "sess-2", conversation_id: "sess-2"}
    end
  end

  describe "BaseAgent spans" do
    test "run stop, llm_call and tool spans carry the same turn id and the session" do
      attach([
        [:normandy, :agent, :run, :stop],
        [:normandy, :agent, :llm_call, :start],
        [:normandy, :tool, :execute, :start]
      ])

      {name, agent} = tool_agent(%{session_id: "sess-3"})
      {config, _} = BaseAgent.run(agent, %{chat_message: "go"})
      turn_id = AgentMemory.get_current_turn_id(config.memory)
      assert is_binary(turn_id)

      assert_received {:span, [:normandy, :agent, :run, :stop],
                       %{agent_name: ^name, turn_id: ^turn_id, session_id: "sess-3"}}

      assert_received {:span, [:normandy, :agent, :llm_call, :start],
                       %{
                         agent_name: ^name,
                         turn_id: ^turn_id,
                         session_id: "sess-3",
                         conversation_id: "sess-3"
                       }}

      assert_received {:span, [:normandy, :tool, :execute, :start],
                       %{
                         agent_name: ^name,
                         turn_id: ^turn_id,
                         session_id: "sess-3",
                         conversation_id: "sess-3"
                       }}
    end

    test "without a session no session keys appear" do
      attach([[:normandy, :agent, :run, :start]])
      {name, agent} = tool_agent(%{})
      BaseAgent.run(agent, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :run, :start], meta}
      assert meta.agent_name == name
      refute Map.has_key?(meta, :session_id)
      refute Map.has_key?(meta, :conversation_id)
    end
  end

  describe "Turn.Server run span" do
    alias Normandy.Agents.Turn

    defp server_config(extra) do
      {_, agent} = tool_agent(%{tool_registry: nil})
      Map.merge(agent, extra)
    end

    defp start_server(sid, config) do
      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      srv
    end

    test "start carries turn id and conversation id; stop shares them" do
      attach([[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :stop]])
      srv = start_server("s-meta", server_config(%{}))

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :run, :start],
                       %{session_id: "s-meta", conversation_id: "s-meta", turn_id: turn_id}}

      assert is_binary(turn_id)

      assert_received {:span, [:normandy, :agent, :run, :stop],
                       %{session_id: "s-meta", turn_id: ^turn_id}}
    end

    test "llm_call spans inside the server carry the session" do
      attach([[:normandy, :agent, :llm_call, :start]])
      srv = start_server("s-meta-llm", server_config(%{}))

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :llm_call, :start],
                       %{session_id: "s-meta-llm", conversation_id: "s-meta-llm", turn_id: _}}
    end

    test "rejected input emits run :start and :exception like BaseAgent, same reply" do
      attach([[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :exception]])

      config = server_config(%{input_guardrails: [{BlockAll, []}]})
      srv = start_server("s-rejected", config)

      assert {:error, {:rejected, %Normandy.Guardrails.ViolationError{}}} =
               Turn.Server.run(srv, %{chat_message: "far too long"})

      assert_received {:span, [:normandy, :agent, :run, :start],
                       %{session_id: "s-rejected"} = start_meta}

      refute Map.has_key?(start_meta, :turn_id)

      assert_received {:span, [:normandy, :agent, :run, :exception],
                       %{
                         session_id: "s-rejected",
                         kind: :error,
                         reason: {:rejected, %Normandy.Guardrails.ViolationError{}}
                       }}

      {_, agent} = tool_agent(%{input_guardrails: [{BlockAll, []}], tool_registry: nil})

      assert_raise Normandy.Guardrails.ViolationError, fn ->
        BaseAgent.run(agent, %{chat_message: "far too long"})
      end

      assert_received {:span, [:normandy, :agent, :run, :start], _}
      assert_received {:span, [:normandy, :agent, :run, :exception], %{kind: :error}}
    end
  end
end
