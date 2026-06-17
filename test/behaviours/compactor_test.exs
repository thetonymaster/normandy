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
end
