defmodule Normandy.Hooks.BaseAgentHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory
  alias Normandy.Hooks.Context
  alias Normandy.Test.{ContextProbe, StreamingProbeClient, StubClient, TelemetryCapture}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe

  defmodule QueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
  end

  # StubClient sends {:converse, %Normandy.LLM.Request{}, opts} to :notify on every LLM call and answers
  # with the response model (test/support/stub_client.ex). retry_options defaults to nil
  # (base_agent.ex:156), so an LLM raise reaches the caller unwrapped.
  defp agent(hooks, extra \\ %{}) do
    %{
      client: %StubClient{notify: self()},
      model: "test",
      name: "hooks-agent",
      behaviours: %Config{hooks: hooks}
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  defp probe(opts \\ []), do: {Probe, [notify: TestHooks.sink(), tag: :p] ++ opts}
  defp input(text), do: %BaseAgentInputSchema{chat_message: text}

  defp user_contents(config) do
    for %{role: "user", content: content} <- AgentMemory.messages(config.memory), do: content
  end

  # Every message in the mailbox, in arrival order.
  defp mailbox do
    receive do
      msg -> [msg | mailbox()]
    after
      0 -> []
    end
  end

  defp raising_client,
    do: %StubClient{reply: fn _ -> raise ArgumentError, "transport blew up" end}

  describe "on_prompt" do
    test "the hook receives the validated input" do
      BaseAgent.run!(agent([probe()], %{input_schema: %QueryInput{}}), %{"query" => "q"})

      assert_received {:hook, :p, :on_prompt,
                       [%QueryInput{query: "q"}, %Context{event: :on_prompt, turn_id: nil}]}
    end

    test "a rewrite is what memory holds" do
      hooks = [probe(returns: [on_prompt: {:cont, input("[redacted]")}])]
      {config, _response} = BaseAgent.run!(agent(hooks), input("my ssn is 1"))

      assert_received {:hook, :p, :on_prompt,
                       [%BaseAgentInputSchema{chat_message: "my ssn is 1"}, _ctx]}

      assert user_contents(config) == [input("[redacted]")]
    end

    test "a plain-map rewrite the schema rejects raises ValidationError before the LLM call" do
      hooks = [probe(returns: [on_prompt: {:cont, %{}}])]
      agent = agent(hooks, %{input_schema: %QueryInput{}})

      assert_raise Normandy.Schema.ValidationError, fn ->
        BaseAgent.run!(agent, %{"query" => "fine"})
      end

      refute_received {:converse, _, _}
    end

    test "a rewrite already of the schema's struct is trusted, as a caller's struct is" do
      hooks = [probe(returns: [on_prompt: {:cont, %QueryInput{query: nil}}])]

      {config, _response} =
        BaseAgent.run!(agent(hooks, %{input_schema: %QueryInput{}}), %{"query" => "q"})

      assert user_contents(config) == [%QueryInput{query: nil}]
    end

    test "a halt raises HookHaltError before memory or the LLM is touched" do
      agent = agent([probe(returns: [on_prompt: {:halt, "off-topic"}])])

      error = assert_raise Normandy.HookHaltError, fn -> BaseAgent.run!(agent, input("hi")) end
      assert %Normandy.HookHaltError{event: :on_prompt, hook: Probe, reason: "off-topic"} = error
      refute_received {:converse, _, _}
    end

    test "a nil input runs no on_prompt hook" do
      BaseAgent.run!(agent([probe()]), nil)
      refute_received {:hook, :p, :on_prompt, _}
    end

    test "runs on the streaming path" do
      config =
        %{
          client: %StreamingProbeClient{},
          model: "test",
          name: "hooks-stream",
          behaviours: %Config{hooks: [probe()]}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      BaseAgent.stream_with_tools(config, input("go"), fn _, _ -> :ok end)

      assert_received {:hook, :p, :on_prompt, [%BaseAgentInputSchema{chat_message: "go"}, _ctx]}
    end
  end

  describe "on_turn_end" do
    test "a completed run reports {:ok, response} with the turn's id, after the run span closes" do
      name = "hooks-turn-end-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :agent, :run, :stop]], agent_name: name)

      {config, response} = BaseAgent.run!(agent([probe()], %{name: name}), input("hi"))

      ordered =
        Enum.filter(
          mailbox(),
          &(match?({:span, _, _}, &1) or match?({:hook, :p, :on_turn_end, _}, &1))
        )

      assert [
               {:span, [:normandy, :agent, :run, :stop], _},
               {:hook, :p, :on_turn_end, [{:ok, ^response}, %Context{turn_id: turn_id}]}
             ] = ordered

      assert turn_id == config.memory.current_turn_id
      refute is_nil(turn_id)
    end

    test "an on_prompt halt reports {:rejected, %HookHaltError{}} with no turn id" do
      agent = agent([probe(returns: [on_prompt: {:halt, "no"}])])
      catch_error(BaseAgent.run!(agent, input("hi")))

      assert_received {:hook, :p, :on_turn_end,
                       [
                         {:rejected, %Normandy.HookHaltError{event: :on_prompt}},
                         %Context{turn_id: nil}
                       ]}
    end

    test "a schema rejection reports {:rejected, %ValidationError{}}" do
      agent = agent([probe()], %{input_schema: %QueryInput{}})
      catch_error(BaseAgent.run!(agent, %{}))

      assert_received {:hook, :p, :on_turn_end,
                       [{:rejected, %Normandy.Schema.ValidationError{}}, _ctx]}
    end

    test "a failing run reports {:error, exception} and raises the original error" do
      agent = agent([probe()], %{client: raising_client()})

      assert_raise ArgumentError, "transport blew up", fn ->
        BaseAgent.run!(agent, input("hi"))
      end

      assert_received {:hook, :p, :on_turn_end,
                       [
                         {:error, %ArgumentError{message: "transport blew up"}},
                         %Context{turn_id: nil}
                       ]}
    end

    @tag :capture_log
    test "a crashing on_turn_end changes neither a result nor a raised error" do
      crashing = [probe(returns: [on_turn_end: {:raise, "audit down"}])]
      assert {_config, _response} = BaseAgent.run!(agent(crashing), input("hi"))

      assert_raise ArgumentError, "transport blew up", fn ->
        BaseAgent.run!(agent(crashing, %{client: raising_client()}), input("hi"))
      end
    end

    test "an on_turn_end return value is ignored, on success and on failure" do
      assert {_config, _response} =
               BaseAgent.run!(agent([probe(returns: [on_turn_end: :done])]), input("hi"))

      failing =
        agent([probe(returns: [on_turn_end: {:error, :audit}])], %{client: raising_client()})

      assert_raise ArgumentError, "transport blew up", fn ->
        BaseAgent.run!(failing, input("hi"))
      end
    end

    test "fires once on the streaming path" do
      config =
        %{
          client: %StreamingProbeClient{},
          model: "test",
          name: "hooks-stream",
          behaviours: %Config{hooks: [probe()]}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      {_config, _response} = BaseAgent.stream_with_tools(config, input("go"), fn _, _ -> :ok end)

      assert_received {:hook, :p, :on_turn_end, [{:ok, _}, _ctx]}
      refute_received {:hook, :p, :on_turn_end, _}
    end
  end
end
