defmodule NormandyTest.Telemetry.MetadataTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, ToolCallResponse}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, ToolCall}
  alias Normandy.Telemetry.Metadata
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Toolset

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
      def converse(config, request, _opts) do
        content =
          if Enum.any?(request.messages, &(&1.role == "tool")) do
            %ToolCallResponse{content: config.final_response, tool_calls: []}
          else
            %ToolCallResponse{
              content: nil,
              tool_calls: [
                %ToolCall{
                  id: "call_1",
                  name: "calculator",
                  input: %{operation: "add", a: 1, b: 2}
                }
              ]
            }
          end

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp tool_agent(extra) do
    name = "metadata-agent-#{System.unique_integer([:positive])}"

    config =
      Map.merge(
        %{
          name: name,
          client: %ToolClient{},
          model: "test-model",
          toolset: Toolset.new([%Calculator{}]),
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
      {name, agent} = tool_agent(%{session_id: "sess-3"})

      TelemetryCapture.attach_span(
        [
          [:normandy, :agent, :run, :stop],
          [:normandy, :agent, :llm_call, :start],
          [:normandy, :tool, :execute, :start]
        ],
        agent_name: name
      )

      {config, _} = BaseAgent.run!(agent, %{chat_message: "go"})
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
      {name, agent} = tool_agent(%{})
      TelemetryCapture.attach_span([[:normandy, :agent, :run, :start]], agent_name: name)
      BaseAgent.run!(agent, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :run, :start], meta}
      assert meta.agent_name == name
      refute Map.has_key?(meta, :session_id)
      refute Map.has_key?(meta, :conversation_id)
    end
  end

  describe "Turn.Server run span" do
    alias Normandy.Agents.Turn

    defp server_config(extra) do
      {_, agent} = tool_agent(%{toolset: nil})
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
      TelemetryCapture.attach_span(
        [[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :stop]],
        session_id: "s-meta"
      )

      srv = start_server("s-meta", server_config(%{}))

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :run, :start],
                       %{session_id: "s-meta", conversation_id: "s-meta", turn_id: turn_id}}

      assert is_binary(turn_id)

      assert_received {:span, [:normandy, :agent, :run, :stop],
                       %{session_id: "s-meta", turn_id: ^turn_id}}
    end

    test "llm_call spans inside the server carry the session" do
      TelemetryCapture.attach_span([[:normandy, :agent, :llm_call, :start]],
        session_id: "s-meta-llm"
      )

      srv = start_server("s-meta-llm", server_config(%{}))

      assert {:ok, _} = Turn.Server.run(srv, %{chat_message: "go"})

      assert_received {:span, [:normandy, :agent, :llm_call, :start],
                       %{session_id: "s-meta-llm", conversation_id: "s-meta-llm", turn_id: _}}
    end

    @tag :capture_log
    test "rejected input emits run :start and :exception like BaseAgent, same reply" do
      TelemetryCapture.attach_span(
        [[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :exception]],
        session_id: "s-rejected"
      )

      config = server_config(%{guardrails: [input: [{BlockAll, []}]]})
      srv = start_server("s-rejected", config)

      assert {:error, %Normandy.Guardrails.ViolationError{}} =
               Turn.Server.run(srv, %{chat_message: "far too long"})

      assert_received {:span, [:normandy, :agent, :run, :start],
                       %{session_id: "s-rejected"} = start_meta}

      refute Map.has_key?(start_meta, :turn_id)

      assert_received {:span, [:normandy, :agent, :run, :exception],
                       %{
                         session_id: "s-rejected",
                         kind: :error,
                         reason: %Normandy.Guardrails.ViolationError{},
                         stacktrace: []
                       }}

      {name, agent} = tool_agent(%{guardrails: [input: [{BlockAll, []}]], toolset: nil})

      TelemetryCapture.attach_span(
        [[:normandy, :agent, :run, :start], [:normandy, :agent, :run, :exception]],
        agent_name: name
      )

      assert_raise Normandy.Guardrails.ViolationError, fn ->
        BaseAgent.run!(agent, %{chat_message: "far too long"})
      end

      assert_received {:span, [:normandy, :agent, :run, :start], %{agent_name: ^name}}

      assert_received {:span, [:normandy, :agent, :run, :exception],
                       %{agent_name: ^name, kind: :error}}
    end
  end
end
