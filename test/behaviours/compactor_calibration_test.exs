defmodule Normandy.Behaviours.CompactorCalibrationTest do
  @moduledoc """
  AX-12: `Compactor.WindowManager` checks the budget against the estimate times the ratio
  of the last reported request size to its estimate (`ToolCallResponse.input_tokens` /
  `estimated_input_tokens`), never below 1: the calibration only compacts earlier.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
  alias Normandy.Components.AgentMemory
  alias Normandy.Context.WindowManager, as: WM

  defp measured(input, estimated),
    do: %ToolCallResponse{
      content: "noted",
      tool_calls: [],
      input_tokens: input,
      estimated_input_tokens: estimated
    }

  defp acc(responses) do
    users = for i <- 1..10, do: {"user", "message number #{i} padding"}

    memory =
      Enum.reduce(
        users ++ Enum.map(responses, &{"assistant", &1}),
        AgentMemory.new_memory(nil),
        fn
          {role, content}, m -> AgentMemory.add_message(m, role, content)
        end
      )

    %{memory: memory}
  end

  # A window the plain estimate fits in with 20% to spare.
  defp roomy(acc),
    do: %{model: "m", window: round(WM.estimate_conversation_tokens(acc.memory) * 1.2) + 16}

  test "a request the provider counted at twice its estimate compacts what the estimate fits" do
    plain = acc([measured(nil, nil)])
    calibrated = acc([measured(2_000, 1_000)])

    assert {_, %{compacted: false, token_ratio: 1.0}} =
             WMCompactor.maybe_compact(plain, roomy(plain), reserved_tokens: 16)

    ctx = roomy(calibrated)

    assert {result, %{compacted: true, token_ratio: 2.0} = meta} =
             WMCompactor.maybe_compact(calibrated, ctx, reserved_tokens: 16)

    assert meta.tokens_after * 2.0 <= ctx.window - 16

    assert length(AgentMemory.history(result.memory)) <
             length(AgentMemory.history(calibrated.memory))
  end

  test "a request counted below its estimate changes nothing (ratio 1.0)" do
    acc = acc([measured(500, 1_000)])

    assert {^acc, %{compacted: false, token_ratio: 1.0}} =
             WMCompactor.maybe_compact(acc, roomy(acc), reserved_tokens: 16)
  end

  test "the newest measured response sets the ratio" do
    acc = acc([measured(3_000, 1_000), measured(1_100, 1_000)])

    assert {_, %{token_ratio: 1.1}} =
             WMCompactor.maybe_compact(acc, roomy(acc), reserved_tokens: 16)
  end

  test "a response without both counts is skipped" do
    acc = acc([measured(2_000, 1_000), measured(5_000, nil), measured(nil, 10)])

    assert {_, %{token_ratio: 2.0}} =
             WMCompactor.maybe_compact(acc, roomy(acc), reserved_tokens: 16)
  end
end
