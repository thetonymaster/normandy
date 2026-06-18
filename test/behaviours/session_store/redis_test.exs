defmodule Normandy.Behaviours.SessionStore.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis
  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.Redis
end
