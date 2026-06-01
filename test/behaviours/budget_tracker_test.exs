defmodule Normandy.Behaviours.BudgetTrackerTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.BudgetTracker

  describe "NoOp" do
    test "check/2 always returns :ok" do
      assert BudgetTracker.NoOp.check(%{agent: "a"}, %{any: :thing}) == :ok
    end

    test "record/2 always returns :ok" do
      assert BudgetTracker.NoOp.record(%{agent: "a"}, %{tokens: 100}) == :ok
    end

    test "implements the BudgetTracker behaviour" do
      behaviours = BudgetTracker.NoOp.module_info(:attributes)[:behaviour] || []
      assert BudgetTracker in behaviours
    end
  end
end
