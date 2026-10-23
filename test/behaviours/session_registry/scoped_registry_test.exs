defmodule Normandy.Behaviours.SessionRegistry.ScopedRegistryTest do
  use ExUnit.Case, async: true

  use Normandy.Test.SessionRegistryContract,
    impl: Normandy.Coordination.AgentProcess.ScopedRegistry
end
