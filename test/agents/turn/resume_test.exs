defmodule Normandy.Agents.Turn.ResumeTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State

  test "resume from :steering re-issues maybe_compact" do
    s = %State{status: :steering, iterations_left: 2, max_iterations: 5}
    assert {^s, [{:maybe_compact, %{iterations_left: 2, mid_round: true}}]} = Turn.resume(s)
  end

  test "resume from :awaiting_approval re-announces the park (resumed: true) and waits" do
    s = %State{
      status: :awaiting_approval,
      parked_calls: [:c],
      iterations_left: 1,
      max_iterations: 5
    }

    assert {^s, [{:emit_event, :awaiting_approval, %{parked: 1, resumed: true}}]} =
             Turn.resume(s)
  end

  describe "resume/2 counts the turn's stored tool rounds" do
    alias Normandy.Agents.ToolCallResponse
    alias Normandy.Components.{Message, ToolCall}

    defp msg(role, content, turn \\ "live"),
      do: %Message{role: role, content: content, turn_id: turn}

    defp call(id), do: msg("assistant", %ToolCallResponse{tool_calls: [%ToolCall{id: id}]})

    # An earlier turn's round, then this turn's `n` rounds.
    defp history(n) do
      [msg("assistant", %ToolCallResponse{tool_calls: [%ToolCall{id: "old"}]}, "earlier")] ++
        [msg("user", "go")] ++ Enum.flat_map(1..n//1, &[call("c#{&1}"), msg("tool", "r")])
    end

    test "a round the saved state missed lowers iterations_left without a notice" do
      s = %State{status: :steering, iterations_left: 4, max_iterations: 5}

      assert {%State{iterations_left: 3}, [{:maybe_compact, %{iterations_left: 3}}]} =
               Turn.resume(s, history(2))
    end

    test "reaching the cap appends the notice once" do
      s = %State{status: :steering, iterations_left: 1, max_iterations: 2}

      assert {%State{iterations_left: 0},
              [{:append_message, "user", notice}, {:maybe_compact, _}]} =
               Turn.resume(s, history(2))

      assert {%State{iterations_left: 0}, [{:maybe_compact, _}]} =
               Turn.resume(s, history(2) ++ [msg("user", notice)])
    end

    test "a state that counts every round, or fewer stored after compaction, is kept" do
      s = %State{status: :steering, iterations_left: 1, max_iterations: 5}
      assert {^s, [{:maybe_compact, %{iterations_left: 1}}]} = Turn.resume(s, history(4))
      assert {^s, [{:maybe_compact, %{iterations_left: 1}}]} = Turn.resume(s, history(1))
      assert {^s, _} = Turn.resume(s, [])
    end
  end

  test "resume from a terminal state is a no-op" do
    for status <- [:stopped, :failed] do
      s = %State{status: status}
      assert {^s, []} = Turn.resume(s)
    end
  end
end
