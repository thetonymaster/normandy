defmodule Normandy.NonDomainRedactionTest do
  # A non-domain exception (a bug) reaches the caller whole, but the persisted turn state
  # and every telemetry :exception reason carry only its module: its fields and its
  # message can hold the value it failed on.
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture
  alias Normandy.TurnError

  @secret "SECRET-sk-redact-me"

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # A key the compiler can't see, so it doesn't flag the fetch that fails by design; the
  # map with the secret still lands in the KeyError and the :erlang.map_get frame.
  defp missing_key, do: String.to_atom("missing")

  defp secret_key_error, do: Map.fetch!(%{api_key: @secret}, missing_key())

  # Every term below is walked in full: no truncation can hide the secret.
  defp leaks?(term), do: inspect(term, limit: :infinity, printable_limit: :infinity) =~ @secret

  # A GenServer.call to a process that raised exits with the exception, its stacktrace
  # (arguments included) and the call, message included.
  defp exit_reason do
    {{%KeyError{key: :k, term: "SECRET-EXC"}, [{M, :f, ["SECRET-ARG"], [line: 1]}]},
     {GenServer, :call, [:server, {:msg, "CALLMSG-2"}, 5000]}}
  end

  defp full(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp agent(name, reply),
    do: BaseAgent.init(%{client: %StubClient{reply: reply}, model: "m", name: name})

  describe "BaseAgent" do
    test "a client's KeyError is raised whole; the run and llm_call telemetry name only KeyError" do
      name = "redact-#{System.unique_integer([:positive])}"

      TelemetryCapture.attach_span(
        [[:normandy, :agent, :run, :exception], [:normandy, :agent, :llm_call, :exception]],
        agent_name: name
      )

      e =
        assert_raise KeyError, fn ->
          BaseAgent.run(agent(name, fn _rm -> secret_key_error() end), %{chat_message: "hi"})
        end

      assert leaks?(e)

      for span <- [:run, :llm_call] do
        assert_received {:span, [:normandy, :agent, ^span, :exception], meta}
        refute leaks?(meta)

        assert %{
                 kind: :error,
                 reason: %TurnError{type: :task_down, reason: %{exception: KeyError}},
                 stacktrace: []
               } = meta
      end
    end

    test "a raw Erlang error is normalized before it is reduced to its module" do
      name = "redact-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :agent, :run, :exception]], agent_name: name)

      raw = fn _rm -> :erlang.error({:badkey, :missing, %{api_key: @secret}}) end

      assert_raise KeyError, fn -> BaseAgent.run(agent(name, raw), %{chat_message: "hi"}) end

      assert_received {:span, [:normandy, :agent, :run, :exception], meta}
      refute leaks?(meta)
      assert %TurnError{type: :task_down, reason: %{exception: KeyError}} = meta.reason
    end

    test "an exit carrying a bug and a stacktrace emits neither; the call message stays" do
      name = "redact-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :agent, :run, :exception]], agent_name: name)

      assert catch_exit(BaseAgent.run(agent(name, fn _rm -> exit(exit_reason()) end), "hi")) ==
               exit_reason()

      assert_received {:span, [:normandy, :agent, :run, :exception], %{kind: :exit} = meta}
      text = full(meta)
      refute text =~ "SECRET-EXC"
      refute text =~ "SECRET-ARG"
      assert text =~ "%{exception: KeyError}"
      # Not an exception: exit payload terms are emitted as they are (Q may decide more).
      assert text =~ "CALLMSG-2"
    end

    test "a domain exception's telemetry reason is unchanged" do
      name = "redact-#{System.unique_integer([:positive])}"
      TelemetryCapture.attach_span([[:normandy, :agent, :run, :exception]], agent_name: name)

      error = Normandy.LLMError.new(type: :rate_limit, retryable?: true, status: 429)

      assert {:error, ^error} =
               BaseAgent.run(agent(name, fn _rm -> {:error, error} end), %{chat_message: "hi"})

      assert_received {:span, [:normandy, :agent, :run, :exception], %{reason: ^error}}
    end
  end

  describe "Turn.Server" do
    defp config do
      %Normandy.Agents.BaseAgentConfig{
        input_schema: nil,
        output_schema: %Resp{},
        client: nil,
        model: "test",
        memory: AgentMemory.new_memory(),
        prompt_specification: %Normandy.Components.PromptSpecification{},
        initial_memory: AgentMemory.new_memory(),
        tool_registry: nil
      }
    end

    defp start_server(sid, handlers) do
      store = InMemory.new()

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: config(),
          store: {InMemory, store},
          registry: {Native, Native.new()},
          handlers: Map.merge(BaseAgent.non_streaming_handlers(), handlers)
        )

      TelemetryCapture.attach_span([[:normandy, :agent, :run, :exception]], session_id: sid)
      {srv, store}
    end

    test "an LLM call's KeyError: the reply holds it, the persisted error and telemetry don't" do
      sid = "redact-llm-#{System.unique_integer([:positive])}"
      {srv, store} = start_server(sid, %{call_llm: fn _c, _s, _r -> secret_key_error() end})

      assert {:error, %TurnError{type: :task_down, reason: %KeyError{}} = replied} =
               Turn.Server.run(srv, "hello")

      assert leaks?(replied)

      assert {:ok, %Turn.State{status: :failed, error: persisted}} =
               InMemory.load_turn_state(store, sid)

      refute leaks?(persisted)
      assert %TurnError{type: :task_down, reason: %{exception: KeyError}} = persisted

      assert_received {:span, [:normandy, :agent, :run, :exception], meta}
      refute leaks?(meta)
      assert %TurnError{type: :task_down, reason: %{exception: KeyError}} = meta.reason
    end

    test "a worker exit carrying a bug: persisted and emitted without it or its stacktrace" do
      sid = "redact-exit-#{System.unique_integer([:positive])}"
      {srv, store} = start_server(sid, %{call_llm: fn _c, _s, _r -> exit(exit_reason()) end})

      assert {:error, %TurnError{type: :task_down, reason: {%KeyError{}, _call}} = replied} =
               Turn.Server.run(srv, "hello")

      assert full(replied) =~ "SECRET-EXC"

      assert {:ok, %Turn.State{status: :failed, error: persisted}} =
               InMemory.load_turn_state(store, sid)

      assert_received {:span, [:normandy, :agent, :run, :exception], meta}

      for term <- [persisted, meta] do
        text = full(term)
        refute text =~ "SECRET-EXC"
        refute text =~ "SECRET-ARG"
        assert text =~ "%{exception: KeyError}"
        assert text =~ "CALLMSG-2"
      end
    end

    test "a handler's KeyError keeps the handler name and loses its fields" do
      sid = "redact-append-#{System.unique_integer([:positive])}"

      {srv, store} =
        start_server(sid, %{
          call_llm: fn _c, _s, _r -> %Resp{content: "answer"} end,
          append: fn _c, _r, _content -> secret_key_error() end
        })

      assert {:error, %TurnError{type: :handler_crashed, reason: %KeyError{}} = replied} =
               Turn.Server.run(srv, "hello")

      assert leaks?(replied)

      assert {:ok, %Turn.State{status: :failed, error: persisted}} =
               InMemory.load_turn_state(store, sid)

      refute leaks?(persisted)

      assert %TurnError{type: :handler_crashed, handler: :append, reason: %{exception: KeyError}} =
               persisted

      assert_received {:span, [:normandy, :agent, :run, :exception], meta}
      refute leaks?(meta)
    end
  end
end
