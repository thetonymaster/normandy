defmodule Normandy.Agents.TurnCompactionTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  describe "steering boundary" do
    test "a completed tool batch parks in :steering and emits :maybe_compact last" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [%ToolCall{id: "c1", name: "t", input: %{}}]
      }

      results = [%ToolResult{tool_call_id: "c1", output: "ok", is_error: false}]
      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.pending_calls == []
      assert s2.awaiting_final == false

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:persist, s2},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4}}
             ]
    end

    test "compaction_done below the cap continues with :iteration + next call" do
      s = %State{
        status: :steering,
        iterations_left: 4,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      {s2, effects} = Turn.step(s, {:compaction_done, %{compacted: false}})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == false

      assert effects == [
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4, final: false}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end

    test "compaction_done at the cap issues the forced-final call" do
      s = %State{
        status: :steering,
        iterations_left: 0,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

      {s2, effects} = Turn.step(s, {:compaction_done, %{compacted: true}})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == true

      assert effects == [
               {:emit_event, :iteration, %{iteration: 6, iterations_left: 0, final: true}},
               {:call_llm, %{response_model: :os, final: true}}
             ]
    end

    defp steering(left),
      do: %State{
        status: :steering,
        iterations_left: left,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os
      }

    test "Turn.new/1 starts tokens_compacted at 0" do
      assert Turn.new().tokens_compacted == 0
    end

    test "a compacted boundary adds tokens_removed (not before - after)" do
      meta = %{
        compacted: true,
        tokens_before: 90_000,
        tokens_after: 30_000,
        tokens_removed: 45_000
      }

      {s2, _} = Turn.step(steering(3), {:compaction_done, meta})
      assert s2.tokens_compacted == 45_000
    end

    test "the forced-final (at-cap) boundary also accumulates" do
      {s2, _} = Turn.step(steering(0), {:compaction_done, %{compacted: true, tokens_removed: 6}})
      assert s2.tokens_compacted == 6
    end

    test "metas without a positive integer tokens_removed leave the counter unchanged" do
      for meta <- [
            %{compacted: false},
            %{},
            %{compacted: false, reason: :no_window},
            %{compacted: true},
            %{compacted: true, tokens_before: 100, tokens_after: 40},
            %{compacted: true, tokens_removed: 0},
            %{compacted: true, tokens_removed: -5},
            %{compacted: true, tokens_removed: nil},
            %{compacted: false, tokens_removed: 500}
          ] do
        {s2, _} = Turn.step(steering(3), {:compaction_done, meta})
        assert s2.tokens_compacted == 0, "meta #{inspect(meta)} changed the counter"
      end
    end

    test "accumulates across boundaries" do
      {s2, _} = Turn.step(steering(3), {:compaction_done, %{compacted: true, tokens_removed: 60}})

      {s3, _} =
        Turn.step(
          %{s2 | status: :steering},
          {:compaction_done, %{compacted: true, tokens_removed: 30}}
        )

      assert s3.tokens_compacted == 90
    end

    test "a state persisted before 2.0 (no :tokens_compacted key) still steps" do
      old = Map.delete(steering(3), :tokens_compacted)

      {s2, effects} = Turn.step(old, {:compaction_done, %{compacted: true, tokens_removed: 30}})

      assert s2.tokens_compacted == 30
      assert {:call_llm, %{response_model: :rm, final: false}} in effects

      {s3, _} =
        Turn.step(
          Map.delete(steering(3), :tokens_compacted),
          {:compaction_done, %{compacted: false}}
        )

      assert s3.status == :assistant_streaming
    end

    test "tokens_compacted survives the durable stores' encoding (term_to_binary, decoded with [:safe])" do
      state = %{steering(3) | tokens_compacted: 1_234}
      decoded = :erlang.binary_to_term(:erlang.term_to_binary(state), [:safe])
      assert decoded.tokens_compacted == 1_234
    end
  end
end
