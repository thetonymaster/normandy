defmodule Normandy.Agents.MidRoundCompactionTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.ContextProbe
  alias Normandy.Test.FakeClient
  alias Normandy.Test.FakeTool
  alias Normandy.Test.TelemetryCapture

  @thinking %{"type" => "thinking", "thinking" => "plan", "signature" => "sig"}

  # Reports each ctx it is called with; never compacts.
  defmodule RecordingCompactor do
    @behaviour Normandy.Behaviours.Compactor

    @impl true
    def maybe_compact(acc, ctx, opts) do
      send(Keyword.fetch!(opts, :notify), {:compact_ctx, ctx})
      {acc, %{compacted: false}}
    end
  end

  # One tool round (a "weather" call with thinking), then the text answer "done".
  # Sends every request to `notify`.
  defmodule OneRoundClient do
    defstruct [:notify, options: %{}]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:request, request})

        content =
          if Enum.any?(request.messages, &(&1.role == "tool")) do
            %ToolCallResponse{content: "done"}
          else
            %ToolCallResponse{
              thinking: [%{"type" => "thinking", "thinking" => "plan", "signature" => "sig"}],
              tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{}}]
            }
          end

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  defp agent(client, compactor) do
    %{
      client: client,
      model: "m",
      name: "mid-round-#{System.unique_integer([:positive])}",
      behaviours: %Config{compactor: compactor}
    }
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%FakeTool{name: "weather"})
  end

  defp recording, do: {RecordingCompactor, [notify: self(), context_window: 200_000]}

  describe "the core marks the boundary" do
    test "turn start is not mid-round; the boundary after a tool batch is" do
      s = Turn.new(max_iterations: 5, response_model: :rm)

      {s, [{:maybe_compact, %{iterations_left: 5, mid_round: false}}]} = Turn.step(s, :start)
      {s, _effects} = Turn.step(s, {:compaction_done, %{}})

      call = %ToolCall{id: "c1", name: "t", input: %{}}
      {s, _effects} = Turn.step(s, {:llm_response, %ToolCallResponse{tool_calls: [call]}})

      {s, effects} =
        Turn.step(s, {:tool_results, [%ToolResult{tool_call_id: "c1", output: "ok"}]})

      assert List.last(effects) == {:maybe_compact, %{iterations_left: 4, mid_round: true}}

      # A persisted :steering state is always a post-batch boundary.
      assert {^s, [{:maybe_compact, %{iterations_left: 4, mid_round: true}}]} = Turn.resume(s)
    end
  end

  describe "every shell hands the compactor ctx.mid_round" do
    test "BaseAgent.run/3, with the telemetry metadata" do
      config = agent(%OneRoundClient{notify: self()}, recording())
      ref = TelemetryCapture.attach([[:normandy, :agent, :compaction]], agent_name: config.name)

      {:ok, _config, _output} = BaseAgent.run(config, %{chat_message: "go"})

      assert_received {:compact_ctx, %{mid_round: false}}
      assert_received {:compact_ctx, %{mid_round: true}}
      refute_received {:compact_ctx, _}

      assert_received {:telemetry, ^ref, _, %{mid_round: false}}
      assert_received {:telemetry, ^ref, _, %{mid_round: true}}
    end

    test "BaseAgent.stream/3" do
      config =
        %{
          client: FakeClient.new([{:tool_calls, [{"probe", %{}}]}, {:text, "done"}]),
          model: "m",
          name: "mid-round-stream",
          behaviours: %Config{compactor: recording()}
        }
        |> BaseAgent.init()
        |> BaseAgent.register_tool(%ContextProbe{})

      {:ok, _config, _output} = BaseAgent.stream(config, %{chat_message: "go"}, fn _ -> :ok end)

      assert_received {:compact_ctx, %{mid_round: false}}
      assert_received {:compact_ctx, %{mid_round: true}}
      refute_received {:compact_ctx, _}
    end

    test "Turn.Server" do
      config = agent(%OneRoundClient{notify: self()}, recording())

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: "mid-round-#{System.unique_integer([:positive])}",
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:ok, _output} = Turn.Server.run(srv, %{chat_message: "go"})

      # The compactor runs in the server's worker tasks: another sender than the reply.
      assert_receive {:compact_ctx, %{mid_round: false}}
      assert_receive {:compact_ctx, %{mid_round: true}}
      refute_received {:compact_ctx, _}
    end
  end

  describe "Compactor.WindowManager at a mid-round boundary" do
    # A tool round whose assistant turn has thinking, after `filler` user messages.
    defp open_round(filler) do
      Enum.reduce(1..filler//1, AgentMemory.new_memory(), fn i, mem ->
        AgentMemory.add_message(mem, "user", "message #{i} with some padding content")
      end)
      |> AgentMemory.add_message("user", "weather?")
      |> AgentMemory.add_message("assistant", %ToolCallResponse{
        thinking: [@thinking],
        tool_calls: [%ToolCall{id: "t1", name: "weather", input: %{}}]
      })
      |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: "t1", output: "sunny"})
    end

    defp assistant_blocks(memory) do
      memory
      |> AgentMemory.history()
      |> Enum.find(&(&1.role == "assistant"))
      |> Map.fetch!(:content)
    end

    test "under the window it leaves memory as it is, thinking included" do
      config = %{agent(%OneRoundClient{notify: self()}, recording()) | memory: open_round(20)}

      {result, meta} =
        WMCompactor.maybe_compact(config, %{model: "m", window: 200_000, mid_round: true}, [])

      assert meta.compacted == false
      assert result.memory == config.memory
      assert @thinking in assistant_blocks(result.memory)
    end

    test "over the window it compacts and strips the kept turns' thinking" do
      config = %{agent(%OneRoundClient{notify: self()}, recording()) | memory: open_round(20)}

      {result, meta} =
        WMCompactor.maybe_compact(
          config,
          %{model: "m", window: 120, mid_round: true},
          reserved_tokens: 16
        )

      assert meta.compacted == true
      blocks = assistant_blocks(result.memory)
      assert Enum.any?(blocks, &match?(%{type: "tool_use"}, &1))
      refute Enum.any?(blocks, &match?(%{"type" => "thinking"}, &1))
    end

    test "the next request of a turn under the window replays the open round's thinking" do
      config =
        agent(%OneRoundClient{notify: self()}, {WMCompactor, [context_window: 200_000]})

      {:ok, _config, _output} = BaseAgent.run(config, %{chat_message: "go"})

      assert_received {:request, _first}
      assert_received {:request, second}

      assistant = Enum.find(second.messages, &(&1.role == "assistant"))
      assert @thinking in assistant.content
    end
  end
end
