defmodule Normandy.Behaviours.MemoryStore.InMemoryTest do
  use ExUnit.Case, async: true
  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.InMemory
end
