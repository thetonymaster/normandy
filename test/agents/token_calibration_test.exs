defmodule Normandy.Agents.TokenCalibrationTest do
  @moduledoc """
  AX-12: a tool-loop response records the size of its request as the provider counted
  it (`ToolCallResponse.input_tokens`: input, cache reads and cache writes of the
  returned call) beside Normandy's estimate of that request when it was sent
  (`estimated_input_tokens`), on `run/3`, `stream/3` and `Turn.Server`.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, ToolCallResponse}
  alias Normandy.Agents.BaseAgent.Prompt
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Test.{FakeClient, FakeTool, TelemetryCapture, WireScript}
  alias Normandy.Tools.Toolset

  @use %{"type" => "tool_use", "id" => "toolu_1", "name" => "weather", "input" => %{}}
  @done %{"type" => "text", "text" => "Sunny."}
  @usage %{
    "input_tokens" => 900,
    "cache_read_input_tokens" => 80,
    "cache_creation_input_tokens" => 20,
    "output_tokens" => 5
  }

  defp agent(client),
    do:
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        toolset: Toolset.new([%FakeTool{}])
      })

  defp tool_round(messages) do
    [round] =
      for %{role: "assistant", content: %ToolCallResponse{tool_calls: [_ | _]} = r} <- messages,
          do: r

    round
  end

  # What Compactor.WindowManager compares for the memory the tool round was asked from:
  # the prompt estimate (ctx.prompt_tokens) plus the history before the round.
  defp compactor_view(config) do
    chain = AgentMemory.entry_chain(config.memory)

    before =
      Enum.take_while(chain, &(not match?(%ToolCallResponse{tool_calls: [_ | _]}, &1.content)))

    Prompt.estimate(config, %ToolCallResponse{}) +
      Enum.reduce(before, 0, &(AgentMemory.entry_tokens(&1) + &2))
  end

  test "run/3 records the reported request size beside its estimate" do
    client =
      WireScript.client([{:json, [@use], "tool_use", @usage}, {:json, [@done], "end_turn"}])

    assert {:ok, config, _} = BaseAgent.run(agent(client), "weather?")

    round = tool_round(AgentMemory.messages(config.memory))
    assert round.input_tokens == 1_000
    assert round.estimated_input_tokens == compactor_view(config)
  end

  test "a custom client's reported usage fills input_tokens when its response has none" do
    client =
      FakeClient.new([
        {:tool_calls, [{"weather", %{}}],
         usage: %{input_tokens: 700, cache_read_input_tokens: 50}},
        {:text, "Sunny."}
      ])

    assert {:ok, config, _} = BaseAgent.run(agent(client), "weather?")

    round = tool_round(AgentMemory.messages(config.memory))
    assert round.input_tokens == 750
    assert round.estimated_input_tokens == compactor_view(config)
  end

  test "with fallback iterations only the returned call counts" do
    usage =
      Map.put(@usage, "iterations", [
        %{"input_tokens" => 5_000, "output_tokens" => 1},
        %{"input_tokens" => 900, "output_tokens" => 5}
      ])

    client = WireScript.client([{:json, [@use], "tool_use", usage}, {:json, [@done], "end_turn"}])

    assert {:ok, config, _} = BaseAgent.run(agent(client), "weather?")
    assert tool_round(AgentMemory.messages(config.memory)).input_tokens == 1_000
  end

  test "stream/3 records them too" do
    tool_use =
      WireScript.message(
        "msg_0",
        WireScript.block(0, %{@use | "input" => %{}}, [
          %{"type" => "input_json_delta", "partial_json" => "{}"}
        ]),
        "tool_use",
        @usage
      )

    done =
      WireScript.message(
        "msg_1",
        WireScript.block(0, %{"type" => "text", "text" => ""}, [
          %{"type" => "text_delta", "text" => "Sunny."}
        ]),
        "end_turn"
      )

    client = WireScript.client([{:sse, tool_use}, {:sse, done}])

    assert {:ok, config, _} = BaseAgent.stream(agent(client), "weather?", fn _ -> :ok end)

    round = tool_round(AgentMemory.messages(config.memory))
    assert round.input_tokens == 1_000
    assert round.estimated_input_tokens == compactor_view(config)
  end

  test "Turn.Server stores them with the response" do
    client =
      WireScript.client([{:json, [@use], "tool_use", @usage}, {:json, [@done], "end_turn"}])

    store = InMemory.new()

    {:ok, srv} =
      Server.start_link(
        session_id: "s-calibration",
        config: agent(client),
        store: {InMemory, store},
        registry: {Native, Native.new()}
      )

    assert {:ok, _} = Server.run(srv, "weather?")
    {:ok, entries} = InMemory.history(store, "s-calibration")

    round = tool_round(Enum.map(entries, &%{role: &1.role, content: &1.content}))
    assert round.input_tokens == 1_000
    assert is_integer(round.estimated_input_tokens) and round.estimated_input_tokens > 0
  end

  # Two turns under a window the estimate fits easily. The second turn's tool call
  # reports its request at `input` tokens; the boundary after the tool batch compacts
  # only when that report makes the conversation too large.
  defp compacted_after_tool_round?(input) do
    client =
      WireScript.client([
        {:json, [%{"type" => "text", "text" => "Hello."}], "end_turn"},
        {:json, [@use], "tool_use", %{"input_tokens" => input, "output_tokens" => 1}},
        {:json, [@done], "end_turn"}
      ])

    config =
      BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5",
        name: "calibrated-#{System.unique_integer([:positive])}",
        toolset: Toolset.new([%FakeTool{}]),
        behaviours: %Config{
          compactor: {WMCompactor, [context_window: 200_000, reserved_tokens: 1_000]}
        }
      })

    {:ok, config, _} = BaseAgent.run(config, "hi")
    ref = TelemetryCapture.attach([[:normandy, :agent, :compaction]], agent_name: config.name)
    {:ok, _config, _} = BaseAgent.run(config, "weather?")

    assert_received {:telemetry, ^ref, _, %{mid_round: false, compacted: false}}

    assert_received {:telemetry, ^ref, _,
                     %{mid_round: true, compacted: compacted, token_ratio: ratio}}

    assert is_float(ratio) and ratio >= 1.0
    compacted
  end

  test "a reported size over the window compacts at the next boundary; a small one does not" do
    refute compacted_after_tool_round?(1)
    assert compacted_after_tool_round?(10_000_000)
  end
end
