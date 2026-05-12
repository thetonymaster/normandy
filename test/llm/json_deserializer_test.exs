defmodule Normandy.LLM.JsonDeserializerTest.WrapperFixtures do
  @moduledoc false

  defmodule MultiField do
    @moduledoc false
    use Normandy.Schema

    io_schema "multi-field schema for wrapper tests" do
      field(:chat_message, :string, description: "message")
      field(:count, :integer, description: "count", default: 0)
    end
  end

  defmodule RequiredField do
    @moduledoc false
    use Normandy.Schema

    io_schema "schema with a required field" do
      field(:chat_message, :string, description: "required message", required: true)
    end
  end
end

defmodule Normandy.LLM.JsonDeserializerTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.JsonDeserializer
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.LLM.JsonDeserializerTest.WrapperFixtures.MultiField
  alias Normandy.LLM.JsonDeserializerTest.WrapperFixtures.RequiredField

  describe "deserialize_with_retry/8" do
    test "parses valid JSON and populates schema" do
      content = ~s({"chat_message": "Hello world"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello world"}} = result
    end

    test "handles JSON with markdown code fences" do
      content = """
      ```json
      {"chat_message": "Hello world"}
      ```
      """

      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello world"}} = result
    end

    test "normalizes field names (response -> chat_message)" do
      content = ~s({"response": "Hello world"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello world"}} = result
    end

    test "normalizes message field to chat_message" do
      content = ~s({"message": "Hello world"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello world"}} = result
    end

    test "normalizes text field to chat_message" do
      content = ~s({"text": "Hello world"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello world"}} = result
    end

    test "returns error for invalid JSON when max_retries is 0" do
      content = "not valid json"
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:error, {:max_retries_reached, _}} = result
    end

    test "handles empty content" do
      content = ""
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:error, {:max_retries_reached, _}} = result
    end

    test "handles whitespace-only content" do
      content = "   \n  \t  "
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:error, {:max_retries_reached, _}} = result
    end

    test "handles JSON with extra whitespace" do
      content = """
        {
          "chat_message"  :  "Hello world"
        }
      """

      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello world"}} = result
    end

    test "handles nested JSON fields" do
      content = ~s({"chat_message": "Hello", "metadata": {"key": "value"}})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello"}} = result
    end

    test "ignores extra fields not in schema" do
      content = ~s({"chat_message": "Hello", "extra_field": "ignored"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello"}} = result
    end

    test "handles multiple markdown code fence styles" do
      content = """
      ```
      {"chat_message": "Without json label"}
      ```
      """

      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Without json label"}} = result
    end

    test "handles strings with escaped quotes" do
      content = ~s({"chat_message": "She said \\"hello\\""})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: ~s(She said "hello")}} = result
    end

    test "handles strings with newlines" do
      content = ~s({"chat_message": "Line 1\\nLine 2"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Line 1\nLine 2"}} = result
    end

    test "handles unicode characters" do
      content = ~s({"chat_message": "Hello 世界 🌍"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          nil,
          nil,
          nil,
          [],
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello 世界 🌍"}} = result
    end
  end

  describe "parse_and_validate/3 — tool-use-style wrapper unwrap" do
    test "bare shape still parses normally (regression guard)" do
      content = ~s({"chat_message": "Hello world", "count": 5})

      assert {:ok, %MultiField{chat_message: "Hello world", count: 5}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Poison)
    end

    test "wrapper shape with matching inner keys is unwrapped" do
      content = ~s({"name": "extract", "arguments": {"chat_message": "hello", "count": 7}})

      assert {:ok, %MultiField{chat_message: "hello", count: 7}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Poison)
    end

    test "wrapper shape with non-matching inner keys returns the empty struct" do
      content = ~s({"name": "extract", "arguments": {"unrelated": "data"}})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Poison)
    end

    test "no arguments key and empty cast preserves current behavior" do
      content = ~s({"name": "extract"})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Poison)
    end

    test "non-map arguments value falls back to empty struct (no crash)" do
      string_args = ~s({"name": "extract", "arguments": "not a map"})
      list_args = ~s({"name": "extract", "arguments": [1, 2, 3]})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(string_args, %MultiField{}, adapter: Poison)

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(list_args, %MultiField{}, adapter: Poison)
    end

    test "required-field validation still fires when neither outer nor inner supplies it" do
      content = ~s({"name": "extract", "arguments": {"unrelated": "data"}})

      assert {:error, {:validation_error, _changeset, _content}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{}, adapter: Poison)
    end

    test "wrapper supplies required field only in inner — unwrap still succeeds" do
      content = ~s({"name": "extract", "arguments": {"chat_message": "hi"}})

      assert {:ok, %RequiredField{chat_message: "hi"}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{}, adapter: Poison)
    end

    test "inner cast error on a permitted key is surfaced, not masked as empty success" do
      content = ~s({"name": "extract", "arguments": {"count": "not_a_number"}})

      assert {:error, {:validation_error, _changeset, _content}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Poison)
    end
  end
end
