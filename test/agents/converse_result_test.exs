defmodule Normandy.Agents.ConverseResultTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ConverseResult

  defmodule R do
    defstruct chat_message: nil
  end

  test "tuple whose first element is a struct passes through" do
    assert {%R{}, %{a: 1}} = ConverseResult.normalize({%R{}, %{a: 1}})
  end

  test "tuple whose first element is a binary passes through" do
    assert {"raw", %{a: 1}} = ConverseResult.normalize({"raw", %{a: 1}})
  end

  test "a bare struct gets nil usage" do
    assert {%R{}, nil} = ConverseResult.normalize(%R{})
  end

  test "a bare binary gets nil usage" do
    assert {"raw", nil} = ConverseResult.normalize("raw")
  end

  test "any other shape is wrapped with nil usage" do
    assert {{:error, :boom}, nil} = ConverseResult.normalize({:error, :boom})
    assert {nil, nil} = ConverseResult.normalize(nil)
  end
end
