defmodule CustomerSupportTest do
  use ExUnit.Case
  doctest CustomerSupport

  test "greets the world" do
    assert CustomerSupport.hello() == :world
  end
end
