defmodule NormandyTest.Components.AgentMemory.EntryTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory.Entry

  test "an Entry carries id, parent_id, turn_id, role, content" do
    entry = %Entry{
      id: "e1",
      parent_id: nil,
      turn_id: "t1",
      role: "user",
      content: %{hello: "world"}
    }

    assert entry.id == "e1"
    assert entry.parent_id == nil
    assert entry.turn_id == "t1"
    assert entry.role == "user"
    assert entry.content == %{hello: "world"}
  end

  test "parent_id defaults to nil (a root entry)" do
    assert %Entry{}.parent_id == nil
  end
end
