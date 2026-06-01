defmodule Normandy.Guardrails.Builtins.LlmRelevanceGuardTest do
  # async: false — Task 3 attaches a global :telemetry handler to this module.
  use ExUnit.Case, async: false

  alias Normandy.Guardrails.Builtins.LlmRelevanceGuard.Decision

  describe "Decision schema" do
    test "carries on_topic and reason" do
      d = %Decision{on_topic: true, reason: "about a wedding"}
      assert d.on_topic == true
      assert d.reason == "about a wedding"
    end

    test "exposes a JSON-encodable specification naming its fields" do
      spec = Decision.__specification__()
      json = Poison.encode!(spec)
      assert json =~ "on_topic"
      assert json =~ "reason"
    end
  end
end
