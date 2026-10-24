defmodule Normandy.Telemetry.RunTotalsTest do
  @moduledoc """
  Task 6.4b (TEL-7, TEL-10, TEL-11): a run's `:stop` carries its totals (llm calls,
  tokens, iterations, stop and finish reason) on `run/3`, `stream/3` and `Turn.Server`;
  an llm_call stop never carries `usage: nil`; `get_response/2` is an llm_call span.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient
  alias Normandy.Test.FakeTool
  alias Normandy.Test.Hooks, as: TestHooks
  alias Normandy.Test.Hooks.Probe
  alias Normandy.Test.StubClient
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  defmodule StopReasonOutput do
    @moduledoc false
    use Normandy.Schema

    io_schema "An answer that explains why the agent stopped" do
      field(:chat_message, :string, description: "The answer")
      field(:stop_reason, :string, description: "Why the agent stopped")
    end
  end

  @weather %{"type" => "tool_use", "id" => "t1", "name" => "weather", "input" => %{}}
  @done %{"type" => "text", "text" => "Done."}
  @run_stop [:normandy, :agent, :run, :stop]
  @token_keys [:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_write_input_tokens]

  defp agent(client, extra \\ %{}) do
    name = "run-totals-#{System.unique_integer([:positive])}"

    config =
      BaseAgent.init(
        Map.merge(
          %{
            client: client,
            model: "claude-opus-5-5",
            name: name,
            toolset: Toolset.new([%FakeTool{}])
          },
          extra
        )
      )

    {name, config}
  end

  defp server(config, session_id, extra \\ []) do
    {:ok, srv} =
      Server.start_link(
        [
          session_id: session_id,
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        ] ++ extra
      )

    srv
  end

  # One tool round, then the answer: two calls, each billed 1 input and 1 output token
  # (WireScript's usage).
  defp json_tool_turn,
    do: WireScript.client([{:json, [@weather], "tool_use"}, {:json, [@done], "end_turn"}])

  defp streamed_tool_turn do
    tool =
      WireScript.message(
        "msg_0",
        WireScript.block(0, @weather, [%{"type" => "input_json_delta", "partial_json" => "{}"}]),
        "tool_use"
      )

    text =
      WireScript.message(
        "msg_1",
        WireScript.block(0, %{"type" => "text", "text" => ""}, [
          %{"type" => "text_delta", "text" => "Done."}
        ]),
        "end_turn"
      )

    WireScript.client([{:sse, tool}, {:sse, text}])
  end

  defp assert_tool_turn_totals(meta) do
    assert %{
             llm_calls: 2,
             input_tokens: 2,
             output_tokens: 2,
             iterations: 1,
             stop_reason: :completed,
             finish_reason: "end_turn"
           } = meta

    refute Map.has_key?(meta, :cache_read_input_tokens)
    refute Map.has_key?(meta, :cache_write_input_tokens)
  end

  describe "a retried failure that billed tokens" do
    @llm_stop [:normandy, :agent, :llm_call, :stop]
    @llm_exception [:normandy, :agent, :llm_call, :exception]

    # A cut-off answer bills its tokens; the default retry policy never retries one.
    defp billed_cutoff do
      error = LLMError.new(type: :max_tokens, retryable?: false)
      {:error, LLMError.with_usage(error, %{input_tokens: 10, output_tokens: 5})}
    end

    defp retry_everything,
      do: [max_attempts: 2, base_delay: 0, jitter: false, retry_if: fn _ -> true end]

    test "a call that succeeds on retry counts the failed attempt's tokens" do
      client =
        FakeClient.new([
          billed_cutoff(),
          {:text, "ok", usage: %{input_tokens: 3, output_tokens: 2}}
        ])

      {name, config} = agent(client, %{retry: retry_everything()})
      TelemetryCapture.attach_span([@llm_stop, @run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "ok"}} = BaseAgent.run(config, "go")

      assert_received {:span, @llm_stop, %{input_tokens: 13, output_tokens: 7}}
      assert_received {:span, @run_stop, %{llm_calls: 1, input_tokens: 13, output_tokens: 7}}
    end

    test "a stream that succeeds on retry counts the failed attempt's tokens" do
      client =
        FakeClient.new([
          billed_cutoff(),
          {:text, "ok", usage: %{input_tokens: 3, output_tokens: 2}}
        ])

      {name, config} = agent(client, %{retry: retry_everything()})
      TelemetryCapture.attach_span([@llm_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "ok"}} =
               BaseAgent.stream(config, "go", fn _event -> :ok end)

      assert_received {:span, @llm_stop, %{input_tokens: 13, output_tokens: 7}}
    end

    test "a call whose every attempt fails reports every attempt's tokens" do
      {name, config} =
        agent(FakeClient.new([billed_cutoff(), billed_cutoff()]), %{retry: retry_everything()})

      TelemetryCapture.attach_span([@llm_exception], agent_name: name)

      assert {:error, %LLMError{type: :max_tokens} = error} = BaseAgent.run(config, "go")
      assert %{input_tokens: 20, output_tokens: 10} = error.usage_counts
      assert_received {:span, @llm_exception, %{reason: %LLMError{usage_counts: counts}}}
      assert %{input_tokens: 20, output_tokens: 10} = counts
    end

    test "without retries the error keeps its own usage" do
      {_name, config} = agent(FakeClient.new([billed_cutoff()]), %{retry: retry_everything()})
      config = %{config | retry: nil}

      assert {:error, %LLMError{usage_counts: %{input_tokens: 10, output_tokens: 5}}} =
               BaseAgent.run(config, "go")
    end
  end

  describe "run :stop totals" do
    test "run/3" do
      {name, config} = agent(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(config, "go")

      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "stream/3" do
      {name, config} = agent(streamed_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(config, "go", fn _event -> :ok end)

      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "Turn.Server" do
      {_name, config} = agent(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], session_id: "s-run-totals")
      srv = server(config, "s-run-totals")

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")

      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "a provider that reports no usage gives the call count and no token keys" do
      {name, config} =
        agent(%StubClient{reply: fn rm -> Map.put(rm, :chat_message, "hi") end}, %{toolset: nil})

      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, _output} = BaseAgent.run(config, "go")

      assert_received {:span, @run_stop, meta}
      assert %{llm_calls: 1, iterations: 0, stop_reason: :completed} = meta
      for key <- @token_keys, do: refute(Map.has_key?(meta, key), "unexpected #{key}")
      # A run without tools answers with its output schema, which has no stop reason.
      refute Map.has_key?(meta, :finish_reason)
    end

    # Through Turn.Server's own :handlers option, not AgentProcess (whose internals 6.5
    # reworks); AgentProcess passes the same handlers to the server.
    test "a custom call_llm handler opens no llm_call span, so the run counts no calls" do
      {_name, config} = agent(%StubClient{}, %{toolset: nil})
      TelemetryCapture.attach_span([@run_stop], session_id: "s-run-totals-custom")

      call_llm = fn _config, _state, _request ->
        %ToolCallResponse{content: "ok", tool_calls: [], stop_reason: :end_turn}
      end

      srv =
        server(config, "s-run-totals-custom",
          handlers: %{AgentHandlers.non_streaming_handlers() | call_llm: call_llm}
        )

      assert {:ok, _} = Server.run(srv, "go")

      assert_received {:span, @run_stop, meta}

      assert %{llm_calls: 0, iterations: 0, stop_reason: :completed, finish_reason: "end_turn"} =
               meta

      for key <- @token_keys, do: refute(Map.has_key?(meta, key), "unexpected #{key}")
    end
  end

  describe "run :stop finish_reason and stop_reason" do
    # An output schema's fields are model text, even one named stop_reason (decision 6).
    test "an output schema's stop_reason field is never read as the finish reason" do
      secret = "model-text-#{System.unique_integer([:positive])}"

      {name, config} =
        agent(
          %StubClient{
            reply: fn _rm -> %StopReasonOutput{chat_message: "hi", stop_reason: secret} end
          },
          %{toolset: nil, output_schema: %StopReasonOutput{}}
        )

      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %StopReasonOutput{stop_reason: ^secret}} =
               BaseAgent.run(config, "go")

      assert_received {:span, @run_stop, meta}
      assert %{llm_calls: 1, stop_reason: :completed} = meta
      refute Map.has_key?(meta, :finish_reason)
      refute inspect(meta) =~ secret
    end

    test "an answer from the final call after max_tool_iterations stops with :max_iterations" do
      {name, config} = agent(json_tool_turn(), %{max_tool_iterations: 1})
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(config, "go")

      assert_received {:span, @run_stop, meta}

      assert %{
               llm_calls: 2,
               iterations: 1,
               stop_reason: :max_iterations,
               finish_reason: "end_turn"
             } = meta
    end
  end

  # The accumulator rides the call request; a before_llm hook is handed only the call's
  # info (Normandy.Hooks.Handlers), so it can neither see nor drop request[:run_usage].
  describe "before_llm hooks and the run accumulator" do
    defp hooked(client) do
      agent(client, %{behaviours: %Config{hooks: [{Probe, notify: TestHooks.sink(), tag: :p}]}})
    end

    defp assert_hook_info_only do
      assert_received {:hook, :p, :before_llm, [info, _ctx]}
      assert Map.keys(info) |> Enum.sort() == [:final, :iterations_left, :reask]
    end

    test "run/3" do
      {name, config} = hooked(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} = BaseAgent.run(config, "go")

      assert_hook_info_only()
      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "stream/3" do
      {name, config} = hooked(streamed_tool_turn())
      TelemetryCapture.attach_span([@run_stop], agent_name: name)

      assert {:ok, _config, %{chat_message: "Done."}} =
               BaseAgent.stream(config, "go", fn _event -> :ok end)

      assert_hook_info_only()
      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end

    test "Turn.Server" do
      {_name, config} = hooked(json_tool_turn())
      TelemetryCapture.attach_span([@run_stop], session_id: "s-run-totals-hooked")
      srv = server(config, "s-run-totals-hooked")

      assert {:ok, %{chat_message: "Done."}} = Server.run(srv, "go")

      assert_hook_info_only()
      assert_received {:span, @run_stop, meta}
      assert_tool_turn_totals(meta)
    end
  end

  describe "llm_call :stop usage (TEL-10)" do
    test "a call whose provider reports no usage has no :usage key" do
      {name, config} =
        agent(%StubClient{reply: fn rm -> Map.put(rm, :chat_message, "hi") end}, %{toolset: nil})

      TelemetryCapture.attach_span([[:normandy, :agent, :llm_call, :stop]], agent_name: name)

      assert {:ok, _config, _output} = BaseAgent.run(config, "go")

      assert_received {:span, [:normandy, :agent, :llm_call, :stop], meta}
      refute Map.has_key?(meta, :usage)
    end
  end

  describe "get_response/2 (TEL-11)" do
    test "is one llm_call span with no iteration, its requests numbered under it" do
      {name, config} = agent(WireScript.client([{:json, [@done], "end_turn"}]), %{toolset: nil})

      TelemetryCapture.attach_span(
        [
          [:normandy, :agent, :llm_call, :start],
          [:normandy, :agent, :llm_call, :stop],
          [:normandy, :llm, :request, :start],
          @run_stop
        ],
        agent_name: name
      )

      _response = BaseAgent.get_response(config)

      assert_received {:span, [:normandy, :agent, :llm_call, :start], start}
      refute Map.has_key?(start, :iteration)
      assert %{stream: false, model: "claude-opus-5-5"} = start

      assert_received {:span, [:normandy, :agent, :llm_call, :stop], stop}
      assert %{attempts: 1, input_tokens: 1, output_tokens: 1} = stop
      assert %{has_tool_calls: false, tool_call_count: 0} = stop

      assert_received {:span, [:normandy, :llm, :request, :start], request}
      assert %{attempt: 1, request_kind: :initial} = request
      refute_received {:span, [:normandy, :llm, :request, :start], _}
      refute_received {:span, @run_stop, _}
    end
  end
end
