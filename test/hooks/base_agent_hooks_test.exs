defmodule Normandy.Hooks.BaseAgentHooksTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory
  alias Normandy.Hooks.Context
  alias Normandy.Test.{ContextProbe, StreamingProbeClient, StubClient}
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe

  defmodule QueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
  end

  # StubClient sends {:converse, messages, opts} to :notify on every LLM call and answers
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

  describe "on_prompt" do
    test "the hook receives the validated input" do
      BaseAgent.run(agent([probe()], %{input_schema: %QueryInput{}}), %{"query" => "q"})

      assert_received {:hook, :p, :on_prompt,
                       [%QueryInput{query: "q"}, %Context{event: :on_prompt, turn_id: nil}]}
    end

    test "a rewrite is what memory holds" do
      hooks = [probe(returns: [on_prompt: {:cont, input("[redacted]")}])]
      {config, _response} = BaseAgent.run(agent(hooks), input("my ssn is 1"))

      assert_received {:hook, :p, :on_prompt,
                       [%BaseAgentInputSchema{chat_message: "my ssn is 1"}, _ctx]}

      assert user_contents(config) == [input("[redacted]")]
    end

    test "a plain-map rewrite the schema rejects raises ValidationError before the LLM call" do
      hooks = [probe(returns: [on_prompt: {:cont, %{}}])]
      agent = agent(hooks, %{input_schema: %QueryInput{}})

      assert_raise Normandy.Schema.ValidationError, fn ->
        BaseAgent.run(agent, %{"query" => "fine"})
      end

      refute_received {:converse, _, _}
    end

    test "a rewrite already of the schema's struct is trusted, as a caller's struct is" do
      hooks = [probe(returns: [on_prompt: {:cont, %QueryInput{query: nil}}])]

      {config, _response} =
        BaseAgent.run(agent(hooks, %{input_schema: %QueryInput{}}), %{"query" => "q"})

      assert user_contents(config) == [%QueryInput{query: nil}]
    end

    test "a halt raises HookHaltError before memory or the LLM is touched" do
      agent = agent([probe(returns: [on_prompt: {:halt, "off-topic"}])])

      error = assert_raise Normandy.HookHaltError, fn -> BaseAgent.run(agent, input("hi")) end
      assert %Normandy.HookHaltError{event: :on_prompt, hook: Probe, reason: "off-topic"} = error
      refute_received {:converse, _, _}
    end

    test "a nil input runs no on_prompt hook" do
      BaseAgent.run(agent([probe()]), nil)
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
end
