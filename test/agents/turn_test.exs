defmodule Normandy.Agents.TurnTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State

  describe "new/1" do
    test "seeds a provisioning state with iterations_left = max_iterations" do
      s = Turn.new(max_iterations: 3, response_model: :rm, output_schema: :os)

      assert %State{
               status: :provisioning,
               max_iterations: 3,
               iterations_left: 3,
               awaiting_final: false,
               response_model: :rm,
               output_schema: :os,
               pending_calls: []
             } = s
    end

    test "defaults max_iterations to 5" do
      assert Turn.new().max_iterations == 5
      assert Turn.new().iterations_left == 5
    end
  end

  describe "step/2 provisioning" do
    test ":start transitions to :assistant_streaming and emits iteration + call_llm" do
      s = Turn.new(max_iterations: 5, response_model: :rm)

      {s2, effects} = Turn.step(s, :start)

      assert s2.status == :assistant_streaming
      assert s2.iterations_left == 5

      assert effects == [
               {:emit_event, :iteration, %{iteration: 1, iterations_left: 5}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end
  end
end
