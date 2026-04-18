defmodule NormandyTest.Agents.BaseAgentLoggingTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema, ToolCallResponse}
  alias Normandy.Components.ToolCall
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  require Logger

  @handler_id :normandy_test_logger_handler

  defmodule NamedDSLAgent do
    use Normandy.DSL.Agent

    agent do
      name("planner")
      model("test-model")
      temperature(0.7)
      max_tokens(2048)
    end
  end

  defmodule LoggingToolCallClient do
    use Normandy.Schema

    schema do
      field(:final_response, :string, default: "Task completed")
    end

    defimpl Normandy.Agents.Model do
      def completitions(_config, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(
            config,
            _model,
            _temperature,
            _max_tokens,
            messages,
            response_model,
            _opts \\ []
          ) do
        tool_message_count = Enum.count(messages, &(&1.role == "tool"))

        cond do
          tool_message_count == 0 ->
            {%ToolCallResponse{
               content: nil,
               tool_calls: [
                 %ToolCall{
                   id: "call_1",
                   name: "calculator",
                   input: %{operation: "add", a: 5, b: 3}
                 }
               ]
             }, %{"input_tokens" => 11, "output_tokens" => 0}}

          tool_message_count > 0 ->
            {%ToolCallResponse{
               content: config.final_response,
               tool_calls: []
             }, %{"input_tokens" => 0, "output_tokens" => 5}}

          true ->
            response_model
        end
      end
    end
  end

  defmodule MetadataHandler do
    def log(event, %{config: %{parent: parent}}) do
      send(parent, {:logger_event, event})
      :ok
    end
  end

  setup do
    :logger.remove_handler(@handler_id)

    :ok =
      :logger.add_handler(@handler_id, MetadataHandler, %{
        level: :debug,
        config: %{parent: self()}
      })

    on_exit(fn ->
      :logger.remove_handler(@handler_id)
    end)

    registry = Registry.new([%Calculator{operation: "add", a: 0, b: 0}])

    agent =
      BaseAgent.init(%{
        client: %LoggingToolCallClient{},
        model: "test-model",
        temperature: 0.7,
        tool_registry: registry,
        max_tool_iterations: 5,
        name: "logging_agent"
      })

    {:ok, agent: agent}
  end

  test "emits structured lifecycle logs for agent, llm, and tool spans", %{agent: agent} do
    {_agent, response} =
      BaseAgent.run(agent, %BaseAgentInputSchema{chat_message: "What is 5 + 3?"})

    assert response.chat_message == "Task completed"
    Logger.flush()

    events = drain_logger_events([])

    messages = Enum.map(events, &logger_message/1)

    assert "normandy agent run start" in messages
    assert "normandy llm call start" in messages
    assert "normandy tool execute start" in messages
    assert "normandy tool execute stop" in messages
    assert "normandy agent run stop" in messages

    assert Enum.count(messages, &(&1 == "normandy llm call start")) == 2
    assert Enum.count(messages, &(&1 == "normandy llm call stop")) == 2

    llm_stop_entries =
      Enum.filter(events, &(logger_message(&1) == "normandy llm call stop"))

    assert Enum.at(llm_stop_entries, 0).meta.input_tokens == 11
    assert Enum.at(llm_stop_entries, 0).meta.output_tokens == 0

    assert Enum.at(llm_stop_entries, 1).meta.input_tokens == 0
    assert Enum.at(llm_stop_entries, 1).meta.output_tokens == 5
  end

  test "uses DSL agent name in lifecycle log metadata" do
    {:ok, agent} = NamedDSLAgent.new(client: %LoggingToolCallClient{})

    {_agent, _response} =
      BaseAgent.run(agent, %BaseAgentInputSchema{chat_message: "Hello from planner"})

    Logger.flush()

    events = drain_logger_events([])

    llm_stop_entry =
      Enum.find(events, &(logger_message(&1) == "normandy llm call stop"))

    assert llm_stop_entry.meta.agent == "planner"
    refute llm_stop_entry.meta.agent == "unnamed_agent"
  end

  defp drain_logger_events(events) do
    receive do
      {:logger_event, event} ->
        drain_logger_events([event | events])
    after
      50 -> Enum.reverse(events)
    end
  end

  defp logger_message(%{msg: {:string, message}}), do: IO.iodata_to_binary(message)
  defp logger_message(%{msg: message}), do: inspect(message)
end
