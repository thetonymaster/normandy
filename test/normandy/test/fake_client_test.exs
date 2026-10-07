defmodule Normandy.Test.FakeClientTest do
  @moduledoc """
  Task 7.3b (DX-8): the shipped `Normandy.Test.FakeClient` answers scripted replies on
  every turn path (`run/3` over `Turn.Driver`, `stream/3`, `Turn.Inline`, `Turn.Server`
  through `Turn.Session`, an `AgentProcess` worker), records every request, and refuses a
  bad script by name.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver
  alias Normandy.Agents.Turn.Inline
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.StreamEvent
  alias Normandy.Components.ToolCall
  alias Normandy.Coordination.AgentProcess
  alias Normandy.LLM.Call
  alias Normandy.LLM.Request
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient
  alias Normandy.Test.FakeClient.ScriptExhaustedError
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  defmodule Weather do
    use Normandy.Tool, name: "weather", description: "The weather in a city"

    defstruct []

    @impl Normandy.Tool
    def input_schema(_tool),
      do: %{type: "object", properties: %{city: %{type: "string"}}, required: ["city"]}

    @impl Normandy.Tool
    def run(_tool, %Normandy.Tools.Context{input: %{"city" => city}}),
      do: {:ok, "cold in #{city}"}
  end

  defmodule Answer do
    use Normandy.Schema

    io_schema "An answer" do
      field(:answer, :string, required: true)
      field(:confidence, :float)
    end
  end

  defp agent(client, extra \\ %{}),
    do: BaseAgent.init(Map.merge(%{client: client, model: "claude-opus-5-5"}, extra))

  defp tool_agent(client, extra \\ %{}),
    do: client |> agent(extra) |> BaseAgent.register_tool(%Weather{})

  defp weather_round, do: {:tool_calls, [{"weather", %{"city" => "Oslo"}}]}

  defp collect, do: fn event -> send(self(), {:event, event}) end

  defp events do
    receive do
      {:event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  defp tool_result_ids(%Request{messages: messages}) do
    for %{role: "tool", content: blocks} <- messages, %{tool_use_id: id} <- blocks, do: id
  end

  describe "run/3 (Turn.Driver)" do
    test "a text reply is the chat answer and the request is recorded" do
      client = FakeClient.new([{:text, "Hello there"}])

      assert {:ok, _agent, %BaseAgentOutputSchema{chat_message: "Hello there"}} =
               BaseAgent.run(agent(client, %{max_tokens: 512}), "hi")

      assert [%Request{model: "claude-opus-5-5", max_tokens: 512, messages: [user]}] =
               FakeClient.requests(client)

      assert user.role == "user"
      assert FakeClient.remaining(client) == 0
    end

    test "a tool round then a text answer runs the tool with a generated call id" do
      client = FakeClient.new([weather_round(), {:text, "It is cold."}])

      assert {:ok, agent, %{chat_message: "It is cold."}} =
               BaseAgent.run(tool_agent(client), "weather?")

      assert ["user", "assistant", "tool", "assistant"] =
               agent.memory |> AgentMemory.messages() |> Enum.map(& &1.role)

      assert [first, second] = FakeClient.requests(client)
      assert first.response_model == %ToolCallResponse{}
      assert [%{name: "weather"}] = first.tools
      assert tool_result_ids(second) == ["toolu_fake_0_0"]
    end

    test "a %ToolCall{} keeps its id" do
      call = %ToolCall{id: "call_1", name: "weather", input: %{"city" => "Rome"}}
      client = FakeClient.new([{:tool_calls, [call]}, {:text, "Warm."}])

      assert {:ok, _agent, %{chat_message: "Warm."}} = BaseAgent.run(tool_agent(client), "q")
      assert [_, second] = FakeClient.requests(client)
      assert tool_result_ids(second) == ["call_1"]
    end

    test "a structured reply fills the output schema, with and without tools" do
      plain = FakeClient.new([{:structured, %{answer: "42", confidence: 0.9}}])

      assert {:ok, _agent, %Answer{answer: "42", confidence: 0.9}} =
               BaseAgent.run(agent(plain, %{output_schema: %Answer{}}), "q")

      tools = FakeClient.new([weather_round(), {:structured, %{answer: "cold"}}])

      assert {:ok, _agent, %Answer{answer: "cold", confidence: nil}} =
               BaseAgent.run(tool_agent(tools, %{output_schema: %Answer{}}), "q")
    end

    test "a text reply is parsed into a non-chat schema; one that is not JSON follows on_parse_failure" do
      ok = FakeClient.new([{:text, ~s({"answer": "42"})}])

      assert {:ok, _agent, %Answer{answer: "42"}} =
               BaseAgent.run(agent(ok, %{output_schema: %Answer{}}), "q")

      bad = FakeClient.new([{:text, "not json"}], options: %{on_parse_failure: :error})

      assert {:error, %LLMError{type: :invalid_output}} =
               BaseAgent.run(agent(bad, %{output_schema: %Answer{}}), "q")
    end

    test "an error reply is returned, and retried when retryable" do
      rate_limited = LLMError.new(type: :rate_limit, retryable?: true)
      client = FakeClient.new([{:error, rate_limited}, {:text, "after retry"}])
      retrying = agent(client, %{retry: [max_attempts: 2, base_delay: 1]})

      assert {:ok, _agent, %{chat_message: "after retry"}} = BaseAgent.run(retrying, "q")
      assert length(FakeClient.requests(client)) == 2

      denied = LLMError.new(type: :authentication, retryable?: false)

      assert {:error, %LLMError{type: :authentication}} =
               BaseAgent.run(agent(FakeClient.new([{:error, denied}])), "q")
    end

    test "stop_reason: :max_tokens is the :max_tokens error; usage is reported" do
      cut = FakeClient.new([{:text, "par", stop_reason: :max_tokens, usage: %{output_tokens: 7}}])

      assert {:error, %LLMError{type: :max_tokens, usage: %{output_tokens: 7}}} =
               BaseAgent.run(agent(cut), "q")
    end

    test "a function item receives the request" do
      client =
        FakeClient.new([
          fn %Request{tool_choice: choice} -> {:text, "tool_choice=#{inspect(choice)}"} end
        ])

      assert {:ok, _agent, %{chat_message: "tool_choice=nil"}} = BaseAgent.run(agent(client), "q")
    end

    test "Turn.Driver with the non-streaming handlers" do
      client = FakeClient.new([weather_round(), {:text, "Driven."}])
      config = client |> tool_agent() |> BaseAgent.admit_turn_input("q")

      state =
        Turn.new(
          max_iterations: 5,
          response_model: %ToolCallResponse{},
          output_schema: config.output_schema
        )

      assert {_config, %Turn.State{status: :stopped, final_response: final}} =
               Driver.drive(state, BaseAgent.non_streaming_handlers(), config)

      assert %BaseAgentOutputSchema{chat_message: "Driven."} = final
      assert length(FakeClient.requests(client)) == 2
    end
  end

  describe "stream/3" do
    test "a tool round then a text answer in chunks, delivered as events" do
      client = FakeClient.new([weather_round(), {:text, ["Co", "ld."]}])

      assert {:ok, _agent, %{chat_message: "Cold."}} =
               BaseAgent.stream(tool_agent(client), "q", collect())

      deltas = for %StreamEvent{type: :text_delta, data: data} <- events(), do: data
      assert deltas == ["Co", "ld."]
      assert [_, second] = FakeClient.requests(client)
      assert tool_result_ids(second) == ["toolu_fake_0_0"]
    end

    test "a structured reply fills the output schema" do
      client = FakeClient.new([{:structured, %{answer: "42"}}])

      assert {:ok, _agent, %Answer{answer: "42"}} =
               BaseAgent.stream(agent(client, %{output_schema: %Answer{}}), "q", collect())
    end

    test "stream_error_after ends the stream in a transport error after that many deltas" do
      client = FakeClient.new([{:text, ["ab", "cd"], stream_error_after: 1}])

      assert {:error, %LLMError{type: :stream}} = BaseAgent.stream(agent(client), "q", collect())

      assert [%StreamEvent{type: :message_start}, %StreamEvent{type: :text_delta, data: "ab"}] =
               events()
    end

    test "an error reply and a cut-off answer are errors" do
      overloaded = LLMError.new(type: :overloaded, retryable?: false)

      assert {:error, %LLMError{type: :overloaded}} =
               BaseAgent.stream(agent(FakeClient.new([{:error, overloaded}])), "q", collect())

      refused = FakeClient.new([{:text, "", stop_reason: :refusal}])

      assert {:error, %LLMError{type: :refusal}} =
               BaseAgent.stream(agent(refused), "q", collect())
    end
  end

  describe "Turn.Inline" do
    test "the client answers the inline shell's calls through Normandy.LLM.Call" do
      client = FakeClient.new([weather_round(), {:text, "Inline."}])
      config = tool_agent(client)

      call_llm = fn _turn_request ->
        request = %Request{
          model: config.model,
          messages: [],
          max_tokens: 64,
          tools: Toolset.to_tool_schemas(config.toolset),
          response_model: %ToolCallResponse{}
        }

        {:ok, response} = Call.converse(client, request, [])
        {:ok, response.content}
      end

      deps = %{
        call_llm: call_llm,
        dispatch: fn calls ->
          Enum.map(
            calls,
            &Dispatch.dispatch_one(config, &1, BaseAgent.base_agent_pipeline(config))
          )
        end
      }

      assert {:ok, %Turn.State{stop_reason: :completed, final_response: final}} =
               Inline.run(Turn.new(max_iterations: 5, response_model: :rm), deps)

      assert %ToolCallResponse{content: "Inline.", stop_reason: :end_turn} = final
      assert FakeClient.remaining(client) == 0
    end
  end

  describe "Turn.Server through Turn.Session" do
    setup do
      store = InMemory.new()
      session_id = "fake-#{System.unique_integer([:positive])}"

      %{
        store: store,
        session_id: session_id,
        opts: [
          session_id: session_id,
          store: {InMemory, store},
          registry: {Native, Native.new()},
          supervisor: start_supervised!(Turn.Supervisor)
        ]
      }
    end

    test "two turns take three replies from the server's worker processes", ctx do
      client = FakeClient.new([weather_round(), {:text, "Cold."}, {:text, "Second turn."}])
      session = Turn.Session.new([config: tool_agent(client)] ++ ctx.opts)

      assert {:ok, %{chat_message: "Cold."}} = Turn.Session.run(session, "weather?")
      assert {:ok, %{chat_message: "Second turn."}} = Turn.Session.run(session, "again")

      assert {:ok, history} = InMemory.history(ctx.store, ctx.session_id)

      assert ["user", "assistant", "tool", "assistant", "user", "assistant"] =
               Enum.map(history, & &1.role)

      assert length(FakeClient.requests(client)) == 3
    end

    test "an exhausted script is a :task_down TurnError carrying the exception", ctx do
      session = Turn.Session.new([config: agent(FakeClient.new([]))] ++ ctx.opts)

      assert {:error,
              %TurnError{type: :task_down, reason: %ScriptExhaustedError{index: 0, scripted: 0}}} =
               Turn.Session.run(session, "q")
    end
  end

  describe "AgentProcess" do
    test "the inline engine's worker process takes the replies" do
      client = FakeClient.new([weather_round(), {:text, "From a process."}])
      pid = start_supervised!({AgentProcess, agent: tool_agent(client)})

      assert {:ok, "From a process."} = AgentProcess.run(pid, "q")
      assert FakeClient.remaining(client) == 0
    end
  end

  describe "the script" do
    test "a request past the last item raises ScriptExhaustedError" do
      client = FakeClient.new([{:text, "one"}])
      assert {:ok, _agent, _} = BaseAgent.run(agent(client), "q")

      error = assert_raise ScriptExhaustedError, fn -> BaseAgent.run(agent(client), "q") end

      assert Exception.message(error) ==
               "Normandy.Test.FakeClient: request 1 has no scripted reply (1 scripted); " <>
                 "add an item to the script passed to new/2"

      assert length(FakeClient.requests(client)) == 2
    end

    test "with retry:, every retry of the raise takes a request index" do
      client = FakeClient.new([])
      retrying = agent(client, %{retry: [max_attempts: 2, base_delay: 1]})

      assert_raise ScriptExhaustedError, fn -> BaseAgent.run(retrying, "q") end
      assert length(FakeClient.requests(client)) == 2
    end

    test "a misspelled item is named" do
      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient.new/2: script item 1 is {:txt, \"hi\"}; expected " <>
                     "{:text, text}, {:structured, map}, {:tool_calls, calls} (each with an " <>
                     "optional keyword list of :stop_reason, :usage, :stream_error_after), " <>
                     "{:error, %Normandy.LLMError{}} or a 1-arity function",
                   fn -> FakeClient.new([{:text, "ok"}, {:txt, "hi"}]) end
    end

    test "an unknown item option, a bad tool call and a bad option are named" do
      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient.new/2: script item 0 has unknown option " <>
                     ":stop; supported: :stop_reason, :usage, :stream_error_after",
                   fn -> FakeClient.new([{:text, "x", stop: :max_tokens}]) end

      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient.new/2: script item 0 is a :tool_calls reply " <>
                     "with the call {:weather, %{}}; expected {name, input} (a binary and a " <>
                     "map) or a %Normandy.Components.ToolCall{}",
                   fn -> FakeClient.new([{:tool_calls, [{:weather, %{}}]}]) end

      assert_raise ArgumentError,
                   ~r/^Normandy.Test.FakeClient.new\/2: unknown option :notify/,
                   fn -> FakeClient.new([], notify: self()) end
    end

    test "a function item that returns a bad item raises when called" do
      client = FakeClient.new([fn _request -> :oops end])

      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient: the function at script item 0 returned an item " <>
                     "that is :oops; expected {:text, text}, {:structured, map}, " <>
                     "{:tool_calls, calls} (each with an optional keyword list of " <>
                     ":stop_reason, :usage, :stream_error_after) " <>
                     "or {:error, %Normandy.LLMError{}}",
                   fn -> BaseAgent.run(agent(client), "q") end
    end

    test "a function item that returns a function raises a named error" do
      client = FakeClient.new([fn _request -> fn _inner -> {:text, "x"} end end])

      assert_raise ArgumentError,
                   "Normandy.Test.FakeClient: the function at script item 0 returned a " <>
                     "function; a function item must return a reply item, not a function " <>
                     "(expected {:text, text}, {:structured, map}, {:tool_calls, calls} " <>
                     "(each with an optional keyword list of :stop_reason, :usage, " <>
                     ":stream_error_after) or {:error, %Normandy.LLMError{}})",
                   fn -> BaseAgent.run(agent(client), "q") end
    end

    test "a client whose building process has exited raises a named error" do
      client = Task.async(fn -> FakeClient.new([{:text, "x"}]) end) |> Task.await()
      message = ~r/the process that built this FakeClient with new\/2 has exited/

      assert_raise ArgumentError, message, fn -> FakeClient.requests(client) end
      assert_raise ArgumentError, message, fn -> BaseAgent.run(agent(client), "q") end
    end

    test "tool calls to an agent without tools raise on run/3 and stream/3" do
      message =
        "Normandy.Test.FakeClient: script item 0 is a :tool_calls reply, but request 0 " <>
          "lists no tools; only an agent with tools receives tool calls (register a tool, " <>
          "or script a :text or :structured reply)"

      assert_raise ArgumentError, message, fn ->
        BaseAgent.run(agent(FakeClient.new([weather_round()])), "q")
      end

      assert_raise ArgumentError, message, fn ->
        BaseAgent.stream(agent(FakeClient.new([weather_round()])), "q", collect())
      end
    end
  end
end
