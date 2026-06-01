defmodule Normandy.Behaviours.PolicyEngineTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.PolicyEngine
  alias Normandy.Components.ToolCall

  describe "AllowAll" do
    test "allows every call regardless of call or ctx" do
      assert PolicyEngine.AllowAll.check(%ToolCall{name: "anything"}, %{}) == {:allow, %{}}

      assert PolicyEngine.AllowAll.check(%{}, %{config: %{}, tool: %{}, opts: []}) ==
               {:allow, %{}}
    end

    test "implements the PolicyEngine behaviour" do
      behaviours = PolicyEngine.AllowAll.module_info(:attributes)[:behaviour] || []
      assert PolicyEngine in behaviours
    end
  end

  describe "Ruleset" do
    defp ctx(rules, default_action) do
      %{opts: [rules: rules, default_action: default_action]}
    end

    test "first matching rule wins (exact name)" do
      rules = [
        %{match: "billing_charge", action: :deny, rule_id: "R-1", rationale: "needs approval"},
        %{match: "*", action: :allow}
      ]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "billing_charge"}, ctx(rules, :allow)) ==
               {:deny, %{reason: "needs approval", rule_id: "R-1", rationale: "needs approval"}}

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :allow)) ==
               {:allow, %{}}
    end

    test "glob prefix match" do
      rules = [%{match: "billing_*", action: :deny, rule_id: "R-2", rationale: "billing blocked"}]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "billing_refund"}, ctx(rules, :allow)) ==
               {:deny, %{reason: "billing blocked", rule_id: "R-2", rationale: "billing blocked"}}

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :allow)) ==
               {:allow, %{}}
    end

    test ":require_approval maps to {:needs_approval, info}" do
      rules = [
        %{match: "deploy", action: :require_approval, rule_id: "R-3", rationale: "prod gate"}
      ]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "deploy"}, ctx(rules, :allow)) ==
               {:needs_approval, %{reason: "prod gate", rule_id: "R-3", rationale: "prod gate"}}
    end

    test "falls back to default_action when nothing matches" do
      rules = [%{match: "billing_*", action: :deny}]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :deny)) ==
               {:deny, %{reason: nil, rule_id: nil, rationale: nil}}

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :allow)) ==
               {:allow, %{}}
    end

    test "implements the PolicyEngine behaviour" do
      behaviours = PolicyEngine.Ruleset.module_info(:attributes)[:behaviour] || []
      assert PolicyEngine in behaviours
    end
  end
end
