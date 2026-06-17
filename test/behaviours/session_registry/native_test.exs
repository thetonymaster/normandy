defmodule Normandy.Behaviours.SessionRegistry.NativeTest do
  use ExUnit.Case, async: true
  use Normandy.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Native
end
