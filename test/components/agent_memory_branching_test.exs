defmodule NormandyTest.Components.AgentMemoryBranchingTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory

  defp ids_in_order(memory) do
    memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)
  end

  test "fork returns {:error, :no_such_entry} for an unknown id" do
    memory = AgentMemory.new_memory() |> AgentMemory.add_message("user", %{a: 1})
    assert AgentMemory.fork(memory, "nope") == {:error, :no_such_entry}
  end

  test "fork diverges from a chosen entry; both branches stay reachable" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", %{c: "a"})
      |> AgentMemory.add_message("assistant", %{c: "b"})
      |> AgentMemory.add_message("user", %{c: "c"})

    [id_a, id_b, id_c] = ids_in_order(memory)

    {:ok, forked} = AgentMemory.fork(memory, id_b)
    forked = AgentMemory.add_message(forked, "assistant", %{c: "d"})

    assert Enum.map(AgentMemory.messages(forked), & &1.content) == [
             %{c: "a"},
             %{c: "b"},
             %{c: "d"}
           ]

    {:ok, original} = AgentMemory.fork(forked, id_c)

    assert Enum.map(AgentMemory.messages(original), & &1.content) == [
             %{c: "a"},
             %{c: "b"},
             %{c: "c"}
           ]

    assert AgentMemory.count_messages(forked) == 4
    assert id_a != id_b
  end
end
