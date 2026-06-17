defmodule Normandy.Behaviours.CompactorTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Compactor

  describe "NoOp default" do
    test "returns the acc unchanged and reports compacted: false" do
      acc = %{memory: :untouched, model: "claude-3-5-sonnet-20241022"}
      ctx = %{model: "claude-3-5-sonnet-20241022", window: 200_000}

      assert {^acc, meta} = Compactor.NoOp.maybe_compact(acc, ctx, [])
      assert meta.compacted == false
    end

    test "ignores ctx and opts entirely (never inspects the window)" do
      acc = :anything

      assert {:anything, %{compacted: false}} =
               Compactor.NoOp.maybe_compact(acc, %{model: nil, window: nil}, foo: :bar)
    end

    test "implements the Compactor behaviour" do
      behaviours = Compactor.NoOp.module_info(:attributes)[:behaviour] || []
      assert Normandy.Behaviours.Compactor in behaviours
    end
  end

  describe "WindowManager impl" do
    alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
    alias Normandy.Components.AgentMemory

    defp mem_with(messages) do
      Enum.reduce(messages, AgentMemory.new_memory(nil), fn {role, content}, m ->
        AgentMemory.add_message(m, role, content)
      end)
    end

    test "no window in ctx and no explicit max_tokens → skips, reason :no_window" do
      acc = %{memory: mem_with([{"user", "hi"}])}

      assert {^acc, %{compacted: false, reason: :no_window}} =
               WMCompactor.maybe_compact(acc, %{model: "mystery", window: nil}, [])
    end

    test "conversation under the window is left untouched" do
      acc = %{memory: mem_with([{"user", "short"}, {"assistant", "ok"}])}

      assert {result, meta} =
               WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, [])

      assert meta.compacted == false
      assert AgentMemory.history(result.memory) == AgentMemory.history(acc.memory)
    end

    test "conversation over the window is truncated (oldest_first default)" do
      # ~25 chars each → ~6 tokens/msg + 10 overhead; 40 messages well exceeds a
      # tiny 80-token window minus 64 reserved.
      msgs = for i <- 1..40, do: {"user", "message number #{i} padding"}
      acc = %{memory: mem_with(msgs)}

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      assert meta.compacted == true
      assert meta.tokens_after < meta.tokens_before
      assert length(AgentMemory.history(result.memory)) < length(AgentMemory.history(acc.memory))
      assert meta.strategy == :oldest_first
    end
  end
end
