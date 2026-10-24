defmodule Normandy.Components.ContentBlock.DescribeTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.ContentBlock.Describe

  describe "reason_term/1" do
    test "keeps atoms, integers and tuples of them whole" do
      assert Describe.reason_term(:timeout) == :timeout
      assert Describe.reason_term({:exit, :noproc}) == {:exit, :noproc}
      assert Describe.reason_term({:namespace_full, :bytes, 10}) == {:namespace_full, :bytes, 10}

      assert Describe.reason_term({:store_exit, {:timeout, {GenServer, :call, 3}}}) ==
               {:store_exit, {:timeout, {GenServer, :call, 3}}}
    end

    test "an exception becomes its module" do
      assert Describe.reason_term(%RuntimeError{message: "password=hunter2"}) == RuntimeError
      assert Describe.reason_term({:boom, %ArgumentError{message: "x"}}) == {:boom, ArgumentError}
    end

    test "a Postgrex.Error with a SQLSTATE becomes {Postgrex.Error, code}" do
      error = %Postgrex.Error{postgres: %{code: :unique_violation, detail: "Key (path)=(/x)"}}
      assert Describe.reason_term(error) == {Postgrex.Error, :unique_violation}
      assert Describe.reason_term(%Postgrex.Error{message: "SELECT 1"}) == Postgrex.Error
    end

    test "strings, maps, lists and other terms become their type, at any depth" do
      assert Describe.reason_term("SELECT secret FROM keys") == "a string (23 bytes)"

      assert Describe.reason_term({:http_error, %{"token" => "SECRET"}, [1, 2]}) ==
               {:http_error, "a map", "a list"}

      assert Describe.reason_term(self()) == "an unsupported term"
    end
  end
end
