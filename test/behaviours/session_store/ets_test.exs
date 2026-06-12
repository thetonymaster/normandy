defmodule Normandy.Behaviours.SessionStore.ETSTest do
  use ExUnit.Case, async: true
  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.ETS
end
