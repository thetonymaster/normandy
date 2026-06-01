defmodule Normandy.Behaviours.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.ModelCatalog

  describe "Static" do
    test "context_window/1 returns the known limit, nil for unknown" do
      assert ModelCatalog.Static.context_window("claude-haiku-4-5-20251001") == 200_000
      assert ModelCatalog.Static.context_window("claude-3-opus-20240229") == 200_000
      assert ModelCatalog.Static.context_window("unknown-model") == nil
    end

    test "get/1 returns context_window + capabilities for known models, :error otherwise" do
      assert {:ok, %{context_window: 200_000, capabilities: caps}} =
               ModelCatalog.Static.get("claude-3-5-sonnet-20241022")

      assert :tools in caps
      assert ModelCatalog.Static.get("unknown-model") == :error
    end

    test "supports?/2 checks capability membership" do
      assert ModelCatalog.Static.supports?("claude-3-haiku-20240307", :vision)
      refute ModelCatalog.Static.supports?("claude-3-haiku-20240307", :code_execution)
      refute ModelCatalog.Static.supports?("unknown-model", :tools)
    end

    test "limits/0 exposes the canonical map (single source of truth)" do
      limits = ModelCatalog.Static.limits()
      assert is_map(limits)
      assert limits["claude-haiku-4-5-20251001"] == 200_000
    end

    test "implements the ModelCatalog behaviour" do
      behaviours = ModelCatalog.Static.module_info(:attributes)[:behaviour] || []
      assert ModelCatalog in behaviours
    end
  end
end
