defmodule Normandy.Agents.ConverseResultTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ConverseResult

  defmodule R do
    defstruct chat_message: nil
  end

  test "a {response, usage, meta} triple passes through" do
    assert {%R{}, %{a: 1}, %{served_by: "m"}} =
             ConverseResult.normalize({%R{}, %{a: 1}, %{served_by: "m"}})
  end

  test "a {struct, usage} pair gains empty meta" do
    assert {%R{}, %{a: 1}, %{}} = ConverseResult.normalize({%R{}, %{a: 1}})
  end

  test "a {binary, usage} pair gains empty meta" do
    assert {"raw", %{a: 1}, %{}} = ConverseResult.normalize({"raw", %{a: 1}})
  end

  test "a bare struct gets nil usage and empty meta" do
    assert {%R{}, nil, %{}} = ConverseResult.normalize(%R{})
  end

  test "a bare binary gets nil usage and empty meta" do
    assert {"raw", nil, %{}} = ConverseResult.normalize("raw")
  end

  test "any other shape is wrapped with nil usage and empty meta" do
    assert {{:error, :boom}, nil, %{}} = ConverseResult.normalize({:error, :boom})
    assert {nil, nil, %{}} = ConverseResult.normalize(nil)
  end

  test "a triple whose meta is not a map raises, naming the shape" do
    error =
      assert_raise ArgumentError, fn -> ConverseResult.normalize({%R{}, %{a: 1}, nil}) end

    assert error.message =~ "meta"
    assert error.message =~ "nil"
  end
end
