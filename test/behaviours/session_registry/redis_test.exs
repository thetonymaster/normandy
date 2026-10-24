defmodule Normandy.Behaviours.SessionRegistry.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis
  use Normandy.Test.SessionRegistryContract,
    impl: Normandy.Behaviours.SessionRegistry.Redis,
    new: {Normandy.TestHandles, :redis_registry, []}
end
