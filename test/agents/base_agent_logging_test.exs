defmodule NormandyTest.Agents.BaseAgentLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema, ToolCallResponse}
  alias Normandy.Components.ToolCall
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Registry

  require Logger

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
             }, %{"input_tokens" => 11, "output_tokens" => 7}}

          tool_message_count > 0 ->
            {%ToolCallResponse{
               content: config.final_response,
               tool_calls: []
             }, %{"input_tokens" => 13, "output_tokens" => 5}}

          true ->
            response_model
        end
      end
    end
  end

  setup do
    console_config = Application.get_env(:logger, :console, [])

    Logger.configure_backend(:console,
      format: "$message $metadata\n",
      metadata: [
        :agent,
        :iteration,
        :max_iterations,
        :iterations,
        :model,
        :tool,
        :duration_ms,
        :status,
        :has_tool_calls,
        :input_tokens,
        :output_tokens
      ]
    )

    on_exit(fn ->
      Logger.configure_backend(:console, console_config)
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
    log =
      capture_log(fn ->
        {_agent, response} =
          BaseAgent.run(agent, %BaseAgentInputSchema{chat_message: "What is 5 + 3?"})

        assert response.chat_message == "Task completed"
        Logger.flush()
      end)

    assert log =~ "normandy agent run start"
    assert log =~ "normandy llm call start"
    assert log =~ "normandy tool execute start"
    assert log =~ "normandy tool execute stop"
    assert log =~ "normandy agent run stop"

    assert length(Regex.scan(~r/normandy llm call start/, log)) == 2
    assert length(Regex.scan(~r/normandy llm call stop/, log)) == 2
  end
end
