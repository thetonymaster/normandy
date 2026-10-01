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

    test "the base input schema is filled without validation" do
      assert {:ok, %BaseAgentInputSchema{chat_message: "hi"}} =
               ValidationMiddleware.validate_input(
                 config(input_schema: %BaseAgentInputSchema{}),
                 %{chat_message: "hi"}
               )
    end

    test "a non-map input passes through" do
      assert ValidationMiddleware.validate_input(config(input_schema: %Query{}), "hi") ==
               {:ok, "hi"}
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

  describe "validation_enabled?/1" do
    test "false with no schemas, true with a validating input schema" do
      refute ValidationMiddleware.validation_enabled?(
               config(input_schema: nil, output_schema: nil)
             )

      assert ValidationMiddleware.validation_enabled?(config(input_schema: %Query{}))
    end

    test "true when only the output schema supports validation" do
      assert ValidationMiddleware.validation_enabled?(
               config(input_schema: %PlainSchema{}, output_schema: %Query{})
             )
    end
  end

  test "error_message lists each path and message" do
    errors = [%{path: [:name], message: "is required"}, %{path: [:age], message: "too low"}]

    assert ValidationMiddleware.error_message(errors) ==
             "Validation failed:\n  - name: is required\n  - age: too low"
  end
end
