defmodule Normandy.Behaviours.AgentTemplateTest do
  use ExUnit.Case, async: true
  alias Normandy.Behaviours.AgentTemplate.Catalog

  test "put then fetch returns the supplement; unknown is :error" do
    {:ok, cat} = Catalog.start_link([])
    supp = %{tool_registry: :tr, before_hooks: [], after_hooks: [], client_builder: fn t -> {:client, t} end}
    assert :ok = Catalog.put(cat, "agent-x", supp)
    assert {:ok, ^supp} = Catalog.fetch(cat, "agent-x")
    assert :error = Catalog.fetch(cat, "missing")
  end
end
