defmodule Normandy.Behaviours.SessionRegistry.HordeTest do
  use ExUnit.Case, async: true
  use Normandy.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Horde
end
