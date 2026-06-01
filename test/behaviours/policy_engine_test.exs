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
end
