defmodule Normandy.Agents.ValidationMiddlewareTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgentConfig, BaseAgentInputSchema, BaseAgentOutputSchema}
  alias Normandy.Agents.ValidationMiddleware

  defmodule Query do
    @moduledoc false
    use Normandy.Schema

    io_schema "a query" do
      field(:query, :string, description: "query", required: true)
    end
  end

  # A struct schema with no Normandy validation support.
  defmodule PlainSchema do
    @moduledoc false
    defstruct [:query]
  end

  defp config(fields), do: struct(BaseAgentConfig, fields)

  describe "validate_input/2" do
    test "no input schema, or nil input, passes through" do
      assert ValidationMiddleware.validate_input(config(input_schema: nil), %{a: 1}) ==
               {:ok, %{a: 1}}

      assert ValidationMiddleware.validate_input(config(input_schema: %Query{}), nil) ==
               {:ok, nil}
    end

    test "a valid map becomes the schema struct" do
      assert {:ok, %Query{query: "hi"}} =
               ValidationMiddleware.validate_input(config(input_schema: %Query{}), %{query: "hi"})
    end

    test "string keys that name a field are used (JSON or form params)" do
      assert {:ok, %Query{query: "hi"}} =
               ValidationMiddleware.validate_input(config(input_schema: %Query{}), %{
                 "query" => "hi",
                 "unknown" => 1
               })

      assert {:ok, %BaseAgentInputSchema{chat_message: "hi"}} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{"chat_message" => "hi"}
               )
    end

    test "a missing required field is an input validation error" do
      assert {:error, [error]} =
               ValidationMiddleware.validate_input(config(input_schema: %Query{}), %{})

      assert error.type == "Input validation error"
      assert error.path == [:query]
    end

    test "a struct of the schema passes through unchanged" do
      input = %Query{query: "hi"}

      assert ValidationMiddleware.validate_input(config(input_schema: %Query{}), input) ==
               {:ok, input}
    end

    test "the base input schema is filled from a valid map" do
      assert {:ok, %BaseAgentInputSchema{chat_message: "hi"}} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{chat_message: "hi"}
               )
    end

    test "the default schema rejects an unknown key instead of sending a nil message" do
      assert {:error, [%{constraint: :unknown_keys, path: [:chat_mesage], message: message}]} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{chat_mesage: "hi"}
               )

      assert message =~ "expected only :chat_message"
    end

    test "the default schema rejects a missing or non-string chat_message" do
      for input <- [%{}, %{chat_message: nil}, %{chat_message: 42}] do
        assert {:error, [%{constraint: :type, path: [:chat_message]}]} =
                 ValidationMiddleware.validate_input(
                   config(input_schema: %BaseAgentInputSchema{}),
                   input
                 )
      end
    end

    test "the default schema still accepts an empty string" do
      assert {:ok, %BaseAgentInputSchema{chat_message: ""}} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{chat_message: ""}
               )
    end

    test "a non-map input for a custom schema is a type error naming the schema" do
      assert {:error, [%{constraint: :type, path: [], message: message}]} =
               ValidationMiddleware.validate_input(config(input_schema: %Query{}), "hi")

      assert message =~ "Query"
      assert message =~ "got: a string"
    end

    test "a string becomes the chat_message of the default schema" do
      assert {:ok, %BaseAgentInputSchema{chat_message: "hi"}} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 "hi"
               )
    end

    test "a default-schema struct is validated, not trusted" do
      assert {:error, [%{constraint: :type, path: [:chat_message]}]} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %BaseAgentInputSchema{chat_message: nil}
               )
    end

    test "with no input schema any input passes through" do
      assert ValidationMiddleware.validate_input(config(input_schema: nil), "hi") == {:ok, "hi"}
    end

    test "a schema without validation support keeps the caller's input" do
      assert ValidationMiddleware.validate_input(config(input_schema: %PlainSchema{}), %{
               query: "hi"
             }) ==
               {:ok, %{query: "hi"}}
    end
  end

  describe "validate_output/2" do
    test "a valid map becomes the schema struct" do
      assert {:ok, %Query{query: "a"}} =
               ValidationMiddleware.validate_output(config(output_schema: %Query{}), %{query: "a"})
    end

    test "an invalid map is an output validation error" do
      assert {:error, [%{type: "Output validation error"}]} =
               ValidationMiddleware.validate_output(config(output_schema: %Query{}), %{})
    end

    test "the base output schema is filled without validation" do
      assert {:ok, %BaseAgentOutputSchema{chat_message: "x"}} =
               ValidationMiddleware.validate_output(
                 config(output_schema: %BaseAgentOutputSchema{}),
                 %{chat_message: "x"}
               )
    end

    test "a schema without validation support keeps the output" do
      assert ValidationMiddleware.validate_output(config(output_schema: %PlainSchema{}), %{
               query: "a"
             }) ==
               {:ok, %{query: "a"}}
    end
  end

  test "error_message lists each path and message" do
    errors = [%{path: [:name], message: "is required"}, %{path: [:age], message: "too low"}]

    assert ValidationMiddleware.error_message(errors) ==
             "Validation failed:\n  - name: is required\n  - age: too low"
  end
end
