defmodule Normandy.Agents.ConverseResultTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ConverseResult

  defmodule R do
    defstruct chat_message: nil
  end

  test "3-tuple with map meta passes through" do
    assert {:ok, {%R{}, %{a: 1}, %{served_by: "m"}}} =
             ConverseResult.normalize({%R{}, %{a: 1}, %{served_by: "m"}})
  end

  test "2-tuple gets empty meta" do
    assert {:ok, {%R{}, %{a: 1}, %{}}} = ConverseResult.normalize({%R{}, %{a: 1}})
  end

  test "raw 2-tuple gets empty meta" do
    assert {:ok, {"raw", %{a: 1}, %{}}} = ConverseResult.normalize({"raw", %{a: 1}})
  end

  test "bare struct" do
    assert {:ok, {%R{}, nil, %{}}} = ConverseResult.normalize(%R{})
  end

  test "bare binary" do
    assert {:ok, {"raw", nil, %{}}} = ConverseResult.normalize("raw")
  end

  test "an LLMError passes through as {:error, e}" do
    e = Normandy.LLMError.new(type: :rate_limit, status: 429, retryable?: true)
    assert {:error, ^e} = ConverseResult.normalize({:error, e})
  end

  test "any other {:error, term} becomes an :unknown LLMError keeping the term" do
    assert {:error, %Normandy.LLMError{type: :unknown, retryable?: false, reason: :boom}} =
             ConverseResult.normalize({:error, :boom})
  end

  test "any other shape raises, naming the function and what came back" do
    for {other, described} <- [
          {nil, "nil"},
          {%{content: "hi"}, "a map"},
          {{:ok, %R{}}, "a {:ok, ...} tuple"}
        ] do
      error = assert_raise ArgumentError, fn -> ConverseResult.normalize(other) end
      assert error.message =~ "ConverseResult.normalize/1"
      assert error.message =~ "got #{described}"
    end
  end

  test "a non-map meta raises, naming the function" do
    assert_raise ArgumentError, ~r/ConverseResult.normalize\/1/, fn ->
      ConverseResult.normalize({%R{}, %{a: 1}, nil})
    end
  end
end
