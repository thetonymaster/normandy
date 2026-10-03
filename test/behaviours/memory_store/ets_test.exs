defmodule Normandy.Behaviours.MemoryStore.ETSTest do
  use ExUnit.Case, async: true
  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.ETS
end
