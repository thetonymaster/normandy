defmodule Normandy.Behaviours.SessionRegistry.HordeTest do
  use ExUnit.Case, async: false
  use Normandy.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Horde
end
