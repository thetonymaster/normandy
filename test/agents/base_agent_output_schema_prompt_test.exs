defmodule Normandy.Agents.BaseAgentOutputSchemaPromptTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.FakeClient
  alias Normandy.Test.StubClient

  defmodule Answer do
    @moduledoc false
    use Normandy.Schema

    io_schema "the agent's answer" do
      field(:verdict, :string, description: "approve or reject", required: true)
      field(:score, :float, description: "confidence from 0 to 1")
    end
  end

  # Declared out of alphabetical and atom-table order (AX-17).
  defmodule Ordered do
    @moduledoc false
    use Normandy.Schema

    io_schema "An answer in declaration order" do
      field(:value, :string, description: "The answer", required: true)
      field(:type, :string)
      field(:name, :string, description: "Who asked")
      field(:id, :integer)
      field(:error, :boolean)
    end
  end

  defmodule Ticket do
    @moduledoc false
    use Normandy.Schema

    io_schema "a support ticket" do
      field(:subject, :string, description: "the customer's one-line summary", required: true)
      field(:priority, :integer, description: "1 (urgent) to 4")
    end
  end

  defp schema_keys(prompt) do
    [_, json] = Regex.run(~r/# OUTPUT SCHEMA\n.*```json\n(.*)\n```/s, prompt)
    properties = Jason.decode!(json, objects: :ordered_objects)["properties"]
    Enum.map(properties.values, &elem(&1, 0))
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

  describe "the input schema block (AX-29)" do
    defp prompt_for(input_schema, input) do
      agent =
        BaseAgent.init(%{
          client: %StubClient{notify: self(), reply: fn rm -> %{rm | verdict: "approve"} end},
          model: "test-model",
          input_schema: input_schema,
          output_schema: %Answer{}
        })

      BaseAgent.run!(agent, input)
      assert_receive {:converse, %Normandy.LLM.Request{system: prompt}, _}
      prompt
    end

    test "a custom input schema is described before the output schema" do
      prompt = prompt_for(%Ticket{}, %{subject: "login fails", priority: 1})

      [_, json] = Regex.run(~r/# INPUT SCHEMA\n.*?```json\n(.*?)\n```/s, prompt)

      assert %{"subject" => %{"description" => "the customer's one-line summary"}} =
               Jason.decode!(json)["properties"]

      [before_output, _] = String.split(prompt, "# OUTPUT SCHEMA")
      assert before_output =~ "# INPUT SCHEMA"
    end

    test "the default input schema, sent as plain text, is not described" do
      refute prompt_for(nil, "hi") =~ "# INPUT SCHEMA"
    end
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

  test "the OUTPUT SCHEMA block keeps declaration order and sends no $schema, title or empty description on every path" do
    order = ["value", "type", "name", "id", "error"]
    stub = %StubClient{notify: self(), reply: fn rm -> %{rm | value: "v"} end}
    agent = BaseAgent.init(%{client: stub, model: "m", output_schema: %Ordered{}})

    assert {:ok, _agent, %Ordered{value: "v"}} = BaseAgent.run(agent, "hi")
    assert_receive {:converse, %Normandy.LLM.Request{system: synced}, _}

    streaming = FakeClient.new([{:text, ~s({"value":"v"})}])

    assert {:ok, _agent, %Ordered{value: "v"}} =
             BaseAgent.stream(%{agent | client: streaming}, "hi", fn _ -> :ok end)

    assert [%Normandy.LLM.Request{system: streamed}] = FakeClient.requests(streaming)

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "wire-#{System.unique_integer([:positive])}",
        config: agent,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, %Ordered{value: "v"}} = Turn.Server.run(srv, "hi")
    assert_receive {:converse, %Normandy.LLM.Request{system: served}, _}

    for prompt <- [synced, streamed, served] do
      assert schema_keys(prompt) == order
      refute prompt =~ "$schema"
      refute prompt =~ ~s("title")
      refute prompt =~ ~s("description": "")
      refute prompt =~ "property_order"
    end
  end
end
