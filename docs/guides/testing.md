# Testing agents

Normandy ships what you need to test an agent without a network or an API key:

- `Normandy.Test.FakeClient`, a model client that answers from a script and records every
  request it receives;
- `Normandy.Test.SessionStoreContract`, `Normandy.Test.MemoryStoreContract` and
  `Normandy.Test.SessionRegistryContract`, the test suites every built-in backend passes,
  for a backend of your own.

Every example below runs in Normandy's own test suite, against the version these docs
describe.

## A scripted model

Give `Normandy.Test.FakeClient.new/2` the replies in the order the agent will ask for
them, and use the client like any other:

```elixir
defmodule MyAppTest.GreeterTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.FakeClient

  test "answers the greeting" do
    client = FakeClient.new([{:text, "Hello, Ada."}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5")

    assert {:ok, _agent, %{chat_message: "Hello, Ada."}} = BaseAgent.run(agent, "I am Ada")
  end

  test "sends the user's message and the agent's max_tokens" do
    client = FakeClient.new([{:text, "Hi."}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5", max_tokens: 512)

    {:ok, _agent, _output} = BaseAgent.run(agent, "I am Ada")

    assert [%Normandy.LLM.Request{max_tokens: 512, messages: [message]}] =
             FakeClient.requests(client)

    assert message.role == "user"
    assert FakeClient.remaining(client) == 0
  end
end
```

`FakeClient.requests/1` returns every `Normandy.LLM.Request` the client received, oldest
first: the system prompt, the messages, the tool schemas and the token limit are what the
model would have seen. A request past the end of the script raises
`Normandy.Test.FakeClient.ScriptExhaustedError`, so a test that makes one call too many
fails loudly. A misspelled script item raises `ArgumentError` from `new/2`, naming it.

## Tools

A tool is a module; the agent runs it when the script asks for it:

```elixir
defmodule MyApp.WeatherTool do
  use Normandy.Tool, name: "weather", description: "The weather in a city"

  defstruct []

  @impl Normandy.Tool
  def input_schema(_tool),
    do: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]}

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %{"city" => city}}),
    do: {:ok, "12°C and raining in #{city}"}
end
```

Script a `{:tool_calls, [{name, input}]}` reply, then the answer the model gives once it
has the result:

```elixir
defmodule MyAppTest.WeatherAgentTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.FakeClient

  defp agent(client) do
    [client: client, model: "claude-opus-5-5"]
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%MyApp.WeatherTool{})
  end

  test "calls the tool, then answers from its result" do
    client =
      FakeClient.new([
        {:tool_calls, [{"weather", %{"city" => "Oslo"}}]},
        {:text, "Bring an umbrella."}
      ])

    assert {:ok, _agent, %{chat_message: "Bring an umbrella."}} =
             BaseAgent.run(agent(client), "Weather in Oslo?")

    [_tool_round, answer_request] = FakeClient.requests(client)
    [_user, _assistant, tool_message] = answer_request.messages
    assert [%{content: "12°C and raining in Oslo", is_error: false}] = tool_message.content
  end

  test "the tool alone" do
    context = %Normandy.Tools.Context{tool_call_id: "call_1", input: %{"city" => "Lima"}}

    assert {:ok, "12°C and raining in Lima"} =
             MyApp.WeatherTool.run(%MyApp.WeatherTool{}, context)
  end
end
```

A tool call's id is `"toolu_fake_<request>_<position>"` (both counted from 0); pass a
`%Normandy.Components.ToolCall{}` instead of `{name, input}` to choose it.

## Structured output, errors and stop reasons

`{:structured, map}` answers with JSON for the agent's output schema. `{:error,
%Normandy.LLMError{}}` fails the call: a `retryable?` error is resent when the agent has
`retry:`. A `:stop_reason` option makes a reply cut off (`:max_tokens`) or refused
(`:refusal`), which Normandy returns as an error:

```elixir
defmodule MyApp.Verdict do
  use Normandy.Schema

  io_schema "A verdict" do
    field(:approved, :boolean, required: true)
    field(:reason, :string)
  end
end
```

```elixir
defmodule MyAppTest.VerdictTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient

  defp agent(client, opts \\ []),
    do: BaseAgent.init([client: client, model: "claude-opus-5-5", output_schema: %MyApp.Verdict{}] ++ opts)

  test "a structured answer" do
    client = FakeClient.new([{:structured, %{approved: true, reason: "within policy"}}])

    assert {:ok, _agent, %MyApp.Verdict{approved: true, reason: "within policy"}} =
             BaseAgent.run(agent(client), "Refund order 42?")
  end

  test "a rate limit is retried" do
    rate_limited = LLMError.new(type: :rate_limit, retryable?: true)
    client = FakeClient.new([{:error, rate_limited}, {:structured, %{approved: false}}])

    assert {:ok, _agent, %MyApp.Verdict{approved: false}} =
             BaseAgent.run(agent(client, retry: [max_attempts: 2, base_delay: 1]), "Refund?")
  end

  test "an answer cut off at max_tokens is an error" do
    client = FakeClient.new([{:text, ~s({"appro), stop_reason: :max_tokens}])

    assert {:error, %LLMError{type: :max_tokens}} = BaseAgent.run(agent(client), "Refund?")
  end
end
```

A function of the request is a script item too, for a reply that depends on what was
sent: `fn %Normandy.LLM.Request{} = request -> {:text, ...} end`.

## Streaming

`BaseAgent.stream/3` takes the same script. A `{:text, chunks}` reply with a list of
binaries arrives as one text delta per chunk:

```elixir
defmodule MyAppTest.StreamingTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.StreamEvent
  alias Normandy.Test.FakeClient

  test "delivers the deltas, then returns the answer" do
    client = FakeClient.new([{:text, ["Hel", "lo."]}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5")
    test_pid = self()

    assert {:ok, _agent, %{chat_message: "Hello."}} =
             BaseAgent.stream(agent, "hi", fn event -> send(test_pid, event) end)

    assert_received %StreamEvent{type: :text_delta, data: "Hel"}
    assert_received %StreamEvent{type: :text_delta, data: "lo."}
  end
end
```

`stream_error_after: n` ends a streamed reply in a transport error after `n` deltas, to
test what your callback does with a partial answer.

## Sessions

A durable session runs its turns in a `Normandy.Agents.Turn.Server` process; the client
answers it there. Start the store, the registry and the supervisor under the test's
supervisor, so they stop with the test:

```elixir
defmodule MyAppTest.SessionTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.FakeClient

  setup do
    registry = :"registry_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: Native, start: {Native, :start_link, [[name: registry]]}})

    %{
      store: start_supervised!(InMemory),
      registry: registry,
      supervisor: start_supervised!(Turn.Supervisor)
    }
  end

  test "two turns of one session", ctx do
    client = FakeClient.new([{:text, "Noted."}, {:text, "You said blue."}])

    session =
      Turn.Session.new(
        session_id: "user-1",
        config: BaseAgent.init(client: client, model: "claude-opus-5-5"),
        store: {InMemory, ctx.store},
        registry: {Native, ctx.registry},
        supervisor: ctx.supervisor
      )

    assert {:ok, %{chat_message: "Noted."}} = Turn.Session.run(session, "My color is blue.")
    assert {:ok, %{chat_message: "You said blue."}} = Turn.Session.run(session, "My color?")

    assert {:ok, history} = InMemory.history(ctx.store, "user-1")
    assert Enum.map(history, & &1.role) == ["user", "assistant", "user", "assistant"]
  end
end
```

## Telemetry

Every run emits `[:normandy, :agent, :run, :stop]` with the run's totals (see
`Normandy.Telemetry`). A `:usage` option on a script item sets what the reply reports:

```elixir
defmodule MyAppTest.UsageTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Test.FakeClient

  test "the run reports its token totals" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:normandy, :agent, :run, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    client = FakeClient.new([{:text, "Hi.", usage: %{input_tokens: 12, output_tokens: 3}}])
    agent = BaseAgent.init(client: client, model: "claude-opus-5-5", name: "usage-test")

    {:ok, _agent, _output} = BaseAgent.run(agent, "hi")

    assert_receive {[:normandy, :agent, :run, :stop], ^ref, _measurements,
                    %{agent_name: "usage-test", input_tokens: 12, output_tokens: 3}}
  end
end
```

Handlers attached this way receive events from every process: match on a field your
test owns (here the agent's name), as `async: true` tests run side by side.

## Hooks

A hook is a module of callbacks; call them directly, or run the hook through an agent
(`BaseAgent.run/3` on a config whose `behaviours` lists it) for the library's rules. See
"Testing a hook" in the [hooks guide](hooks.md).

## A store or registry of your own

Run the contract suite the built-in backends pass. `impl:` is your module; `new:` builds a
fresh, empty handle for each test (default `{impl, :new, []}`):

```elixir
defmodule MyAppTest.SessionStoreTest do
  use ExUnit.Case, async: true

  use Normandy.Test.SessionStoreContract,
    impl: MyApp.SessionStore,
    new: {MyApp.SessionStore, :new, []}
end
```

`Normandy.Test.MemoryStoreContract` and `Normandy.Test.SessionRegistryContract` take the
same options. Each module's documentation says what a handle must provide and when a backend
needs `async: false`.

## A client of your own

To test an adapter for another provider, implement `Normandy.Agents.Model` (its
documentation is the contract). Two things differ from `FakeClient`:

- **Protocol consolidation.** A `defimpl` in a `.exs` test file is not used once protocols
  are consolidated. Put the implementation in a file compiled with your project (for
  example `test/support/`, added to `elixirc_paths` for the test environment), or set
  `consolidate_protocols: false` for the test environment in `mix.exs`.
- **Process ownership.** A `Turn.Server` session, an `AgentProcess` and BaseAgent's tool
  tasks call the client from their own processes. `Req.Test` and Mox expectations
  need an allowance for those pids (see `MIGRATING-2.0.md`, "AgentProcess and
  coordination"). `FakeClient` needs none: any process on the node takes the next reply.

## Live tests

Keep tests that call a real model out of the default run. Tag them, exclude the tag in
`test/test_helper.exs`, and run them with `mix test --only integration`:

    ExUnit.start(exclude: [:integration])

    @tag :integration
    test "the live model answers" do
      ...
    end
