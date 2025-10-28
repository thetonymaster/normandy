defmodule Normandy.LLM.JsonDeserializerTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.JsonDeserializer
  alias Normandy.Agents.BaseAgentOutputSchema

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
end
