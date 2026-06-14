defmodule Normandy.Behaviours.SessionStore.InMemoryTest do
  use ExUnit.Case, async: true
  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory
end
