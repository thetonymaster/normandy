defmodule Normandy.Behaviours.SessionRegistry.HordeTest do
  use ExUnit.Case, async: true
  use Normandy.Test.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Horde
end
