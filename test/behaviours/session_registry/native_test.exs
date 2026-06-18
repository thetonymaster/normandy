defmodule Normandy.Behaviours.SessionRegistry.NativeTest do
  use ExUnit.Case, async: true
  use Normandy.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Native

  test "Native.child_name/2 is :self_register" do
    assert Normandy.Behaviours.SessionRegistry.Native.child_name(:some_handle, "s1") ==
             :self_register
  end
end
