defmodule Normandy.Agents.BaseAgentOutputSchemaPromptTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent

  defmodule PromptCapture do
    @moduledoc false
    use Normandy.Schema

    schema do
      field(:test_pid, :any)
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
        do: response_model

      def converse(client, _model, _temperature, _max_tokens, messages, response_model, _opts) do
        send(client.test_pid, {:system_prompt, hd(messages).content})
        response_model
      end
    end
  end

  defmodule Answer do
    @moduledoc false
    use Normandy.Schema

    io_schema "the agent's answer" do
      field(:verdict, :string, description: "approve or reject", required: true)
      field(:score, :float, description: "confidence from 0 to 1")
    end
  end

  defp system_prompt(output_schema) do
    agent =
      BaseAgent.init(%{
        client: %PromptCapture{test_pid: self()},
        model: "test-model",
        output_schema: output_schema
      })

    BaseAgent.run(agent, "hi")
    assert_receive {:system_prompt, prompt}
    prompt
  end

  test "the output schema block is the schema's JSON Schema" do
    prompt = system_prompt(%Answer{})

    assert prompt =~ "# OUTPUT SCHEMA"
    assert prompt =~ "approve or reject"
    assert prompt =~ ~s("required")
    assert prompt =~ ~s("verdict")
    assert prompt =~ ~s("number")
  end
end
