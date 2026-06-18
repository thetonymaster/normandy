defmodule Normandy.Behaviours.SessionStore.MnesiaTest do
  # async: false — Mnesia is node-global state; keep these serialized even though
  # each `new/0` makes uniquely-named tables.
  use ExUnit.Case, async: false
  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.Mnesia
end
