defmodule Normandy.Behaviours.SessionRegistry.NativeTest do
  use ExUnit.Case, async: true
  use Normandy.Test.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Native

  alias Normandy.Behaviours.SessionRegistry.Native

  test "Native.child_name/2 is :self_register" do
    assert Native.child_name(:some_handle, "s1") ==
             :self_register
  end
end
