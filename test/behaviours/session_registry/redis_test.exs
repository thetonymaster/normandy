defmodule Normandy.Behaviours.SessionRegistry.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis
  use Normandy.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Redis
end
