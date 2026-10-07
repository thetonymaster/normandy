defmodule Normandy.Behaviours.MemoryStore.InMemoryTest do
  use ExUnit.Case, async: true
  use Normandy.Test.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.InMemory

  alias Normandy.Behaviours.MemoryStore.InMemory

  # The contract only checks the message loosely; this pins Normandy's own wording.
  test "an unknown limit names put/6, the key and the supported keys" do
    handle = InMemory.new()

    assert_raise ArgumentError,
                 "#{inspect(InMemory)}.put/6: unknown option :max_byte; supported: :max_bytes, :max_documents",
                 fn -> InMemory.put(handle, "ns", "/memories/a", "x", :new, max_byte: 1) end
  end
end
