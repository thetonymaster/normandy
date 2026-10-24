defmodule Normandy.Agents.OutputConstraintRetryTest do
  @moduledoc """
  AX-18: an answer that parses but breaks a constraint the API does not enforce (a
  pattern, a length, a range) is re-asked with the validation errors, on the structured
  and the legacy path, up to `json_retry_max_attempts`.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Schema.ValidationError
  alias Normandy.Test.FakeClient
  alias Normandy.Test.TelemetryCapture

  defmodule Code3 do
    @moduledoc false
    use Normandy.Schema

    io_schema "a three-letter code" do
      field(:code, :string, required: true, pattern: "^[A-Z]{3}$", description: "3 capitals")
    end
  end

  defp agent(script, structured?, extra \\ %{}) do
    client = FakeClient.new(script, options: %{structured_outputs: structured?})

    config =
      BaseAgent.init(Map.merge(%{client: client, model: "m", output_schema: %Code3{}}, extra))

    {client, config}
  end

  for structured? <- [true, false] do
    test "a broken constraint is re-asked with the errors (structured_outputs: #{structured?})" do
      {client, config} =
        agent(
          [
            {:text, ~s({"code": "abcd"}), usage: %{input_tokens: 10, output_tokens: 3}},
            {:text, ~s({"code": "ABC"}), usage: %{input_tokens: 12, output_tokens: 3}}
          ],
          unquote(structured?)
        )

      TelemetryCapture.attach_span([[:normandy, :agent, :run, :stop]], agent_name: config.name)

      assert {:ok, _config, %Code3{code: "ABC"}} = BaseAgent.run(config, "go")
      assert [first, retry] = FakeClient.requests(client)

      assert_received {:span, [:normandy, :agent, :run, :stop],
                       %{llm_calls: 1, input_tokens: 22, output_tokens: 6}}

      feedback = List.last(retry.messages)
      assert feedback.role == "user"
      assert feedback.content =~ "must match pattern"
      assert length(retry.messages) == length(first.messages) + 1
    end
  end

  test "the retries are bounded by json_retry_max_attempts, then the error stands" do
    bad = {:text, ~s({"code": "abcd"})}
    {client, config} = agent([bad, bad, bad], true, %{json_retry_max_attempts: 2})

    assert {:error, %ValidationError{}} = BaseAgent.run(config, "go")
    assert length(FakeClient.requests(client)) == 3
  end

  test "a constraint re-ask makes no JSON parse retries of its own" do
    alias Normandy.Test.WireScript

    client =
      WireScript.client(
        [
          {:json, [%{"type" => "text", "text" => ~s({"code": "abcd"})}], "end_turn"},
          {:json, [%{"type" => "text", "text" => "not json at all"}], "end_turn"}
        ],
        %{structured_outputs: false}
      )

    config =
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        output_schema: %Code3{},
        json_retry_max_attempts: 1
      })

    assert {:error, _exception} = BaseAgent.run(config, "go")
    assert_receive {:wire_body, 0, _}
    assert_receive {:wire_body, 1, _}
    refute_receive {:wire_body, 2, _}
  end

  test "a tool-loop answer is re-asked by the turn, answer only, then rejected" do
    client = %Normandy.Test.StubClient{
      notify: self(),
      reply: fn _response_model -> %Code3{code: "abcd"} end
    }

    config =
      %{client: client, model: "m", output_schema: %Code3{}}
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%Normandy.Test.FakeTool{})

    # The first call, then json_retry_max_attempts (default 2) re-asks with
    # tool_choice :none (AX-18), then the ValidationError.
    assert {:error, %ValidationError{}} = BaseAgent.run(config, "go")
    assert_receive {:converse, %{response_model: %Normandy.Agents.ToolCallResponse{}}, _}
    assert_receive {:converse, %{tool_choice: :none}, _}
    assert_receive {:converse, %{tool_choice: :none}, _}
    refute_receive {:converse, _, _}
  end

  test "an OpenAI-compatible client's answer is re-asked too" do
    alias Normandy.LLM.OpenAICompatibleAdapter

    {:ok, answers} = Agent.start_link(fn -> [~s({"code": "abcd"}), ~s({"code": "ABC"})] end)
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      content = Agent.get_and_update(answers, fn [next | rest] -> {next, rest} end)

      Req.Test.json(conn, %{
        "id" => "chatcmpl-1",
        "choices" => [%{"message" => %{"content" => content}, "finish_reason" => "stop"}]
      })
    end)

    client = %OpenAICompatibleAdapter{
      api_key: "test-key",
      base_url: "https://example.test/v1",
      options: %{req_options: [plug: {Req.Test, name}]}
    }

    config = BaseAgent.init(%{client: client, model: "gpt-4o", output_schema: %Code3{}})

    assert {:ok, _config, %Code3{code: "ABC"}} = BaseAgent.run(config, "go")
    assert Agent.get(answers, & &1) == []
  end

  test "enable_json_retry: false asks once" do
    {client, config} = agent([{:text, ~s({"code": "abcd"})}], true, %{enable_json_retry: false})

    assert {:error, %ValidationError{}} = BaseAgent.run(config, "go")
    assert length(FakeClient.requests(client)) == 1
  end
end
