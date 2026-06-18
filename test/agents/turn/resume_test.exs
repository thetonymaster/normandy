defmodule Normandy.Agents.Turn.ResumeTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State

  test "resume from :steering re-issues maybe_compact" do
    s = %State{status: :steering, iterations_left: 2, max_iterations: 5}
    assert {^s, [{:maybe_compact, %{iterations_left: 2}}]} = Turn.resume(s)
  end

  test "resume from :awaiting_approval emits no effects (waits for approval)" do
    s = %State{
      status: :awaiting_approval,
      parked_calls: [:c],
      iterations_left: 1,
      max_iterations: 5
    }

    assert {^s, []} = Turn.resume(s)
  end

  test "resume from a terminal state is a no-op" do
    for status <- [:stopped, :failed] do
      s = %State{status: status}
      assert {^s, []} = Turn.resume(s)
    end
  end
end
