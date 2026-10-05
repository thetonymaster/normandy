defmodule Normandy.Agents.BaseAgentOutputSchemaPromptTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.StubClient

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
        client: %StubClient{notify: self(), reply: fn rm -> %{rm | verdict: "approve"} end},
        model: "test-model",
        output_schema: output_schema
      })

    BaseAgent.run!(agent, "hi")
    assert_receive {:converse, %Normandy.LLM.Request{system: prompt}, _}
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

  test "a tool-using agent is not told to answer in the internal ToolCallResponse shape" do
    agent =
      BaseAgent.init(%{
        client: %StubClient{
          notify: self(),
          reply: fn rm -> %{rm | content: "plain answer", tool_calls: []} end
        },
        model: "test-model"
      })
      |> BaseAgent.register_tool(%Normandy.Tools.Examples.Calculator{})

    {_agent, response} = BaseAgent.run!(agent, "hi")

    assert_receive {:converse, %Normandy.LLM.Request{system: prompt}, _}
    refute prompt =~ "tool_calls"
    refute prompt =~ "prefix_key"
    assert response.chat_message == "plain answer"
  end
end
