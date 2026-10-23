defmodule Normandy.LLM.JsonDeserializerTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.Json.TestFixtures.RecoveryFixture
  alias Normandy.LLM.Json.TestFixtures.RequiredField
  alias Normandy.LLM.JsonDeserializer

  # max_retries: 0 never reaches the client, so the request is only carried.
  @request %Normandy.LLM.Request{model: "m", messages: [], max_tokens: 1024}

  describe "deserialize_with_retry/5" do
    test "parses valid JSON and populates schema" do
      content = ~s({"chat_message": "Hello world"})
      schema = %BaseAgentOutputSchema{}

      result =
        JsonDeserializer.deserialize_with_retry(
          content,
          schema,
          nil,
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
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
          @request,
          max_retries: 0
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "Hello 世界 🌍"}} = result
    end
  end

  describe "parse_and_validate/3 — tool-use-style wrapper unwrap" do
    test "bare shape still parses normally (regression guard)" do
      content = ~s({"chat_message": "Hello world", "count": 5})

      assert {:ok, %MultiField{chat_message: "Hello world", count: 5}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Normandy.JSON)
    end

    test "wrapper shape with matching inner keys is unwrapped" do
      content = ~s({"name": "extract", "arguments": {"chat_message": "hello", "count": 7}})

      assert {:ok, %MultiField{chat_message: "hello", count: 7}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Normandy.JSON)
    end

    test "wrapper shape with non-matching inner keys returns the empty struct" do
      content = ~s({"name": "extract", "arguments": {"unrelated": "data"}})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Normandy.JSON)
    end

    test "no arguments key and empty cast preserves current behavior" do
      content = ~s({"name": "extract"})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Normandy.JSON)
    end

    test "non-map arguments value falls back to empty struct (no crash)" do
      string_args = ~s({"name": "extract", "arguments": "not a map"})
      list_args = ~s({"name": "extract", "arguments": [1, 2, 3]})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(string_args, %MultiField{},
                 adapter: Normandy.JSON
               )

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(list_args, %MultiField{},
                 adapter: Normandy.JSON
               )
    end

    test "required-field validation still fires when neither outer nor inner supplies it" do
      content = ~s({"name": "extract", "arguments": {"unrelated": "data"}})

      assert {:error, {:validation_error, _changeset, _content}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{},
                 adapter: Normandy.JSON
               )
    end

    test "wrapper supplies required field only in inner — unwrap still succeeds" do
      content = ~s({"name": "extract", "arguments": {"chat_message": "hi"}})

      assert {:ok, %RequiredField{chat_message: "hi"}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{},
                 adapter: Normandy.JSON
               )
    end

    test "inner cast error on a permitted key is surfaced, not masked as empty success" do
      content = ~s({"name": "extract", "arguments": {"count": "not_a_number"}})

      assert {:error, {:validation_error, _changeset, _content}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{}, adapter: Normandy.JSON)
    end
  end

  describe "parse_and_validate/3 — removed :recover_truncated_strings option" do
    test "the option is no longer read: a truncated string stays a parse error" do
      # Options are not schema-validated here, so an unknown key is ignored.
      truncated = ~s({"page_text": "hello world\\n\\n\\n\\n)

      assert {:error, {:json_parse_error, _, _}} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Normandy.JSON,
                 recover_truncated_strings: true
               )
    end
  end

  describe "characterization — return shapes (parse_and_validate/3)" do
    test "valid JSON returns {:ok, struct}" do
      assert {:ok, %MultiField{chat_message: "hi", count: 0}} =
               JsonDeserializer.parse_and_validate(~s({"chat_message": "hi"}), %MultiField{})
    end

    test "unparseable content returns {:error, {:json_parse_error, reason, content}}" do
      assert {:error, {:json_parse_error, _reason, "not json"}} =
               JsonDeserializer.parse_and_validate("not json", %MultiField{})
    end

    test "missing required field returns {:error, {:validation_error, changeset, content}}" do
      content = ~s({"count": 5})

      assert {:error, {:validation_error, changeset, ^content}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{})

      refute changeset.valid?
    end

    test "non-map top-level JSON returns an unexpected_parse_result tuple" do
      assert {:error, {:unexpected_parse_result, "[1, 2, 3]"}} =
               JsonDeserializer.parse_and_validate("[1, 2, 3]", %MultiField{})
    end
  end

  describe "hardening — prose-wrapped JSON extraction" do
    test "extracts and parses JSON wrapped in explanatory prose" do
      content = ~s(Sure! Here is the result: {"chat_message": "ok"} — anything else?)

      assert {:ok, %MultiField{chat_message: "ok"}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end

    test "bare valid JSON is unaffected (happy path unchanged)" do
      assert {:ok, %MultiField{chat_message: "hi"}} =
               JsonDeserializer.parse_and_validate(~s({"chat_message": "hi"}), %MultiField{})
    end

    test "skips a balanced non-JSON fragment and parses a later valid object" do
      content = ~s(Note: {nope} then {"chat_message": "real"})

      assert {:ok, %MultiField{chat_message: "real"}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end

    test "skips a valid-JSON-but-unbindable object and parses a later valid one" do
      # First object is valid JSON but fails RequiredField binding (no chat_message);
      # the later object binds. Recovery must not stop at the first bind failure.
      content = ~s(First {"count": 1} then {"chat_message": "real"})

      assert {:ok, %RequiredField{chat_message: "real"}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{})
    end

    test "preserves the validation error when no extracted region binds" do
      content = ~s(Only: {"count": 1} here)

      assert {:error, {:validation_error, _changeset, _}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{})
    end
  end

  describe "characterization — validation error detail is preserved" do
    test "changeset exposes the missing required field for feedback formatting" do
      assert {:error, {:validation_error, changeset, _}} =
               JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

      errors = Normandy.Validate.traverse_errors(changeset, fn {msg, _opts} -> msg end)
      assert Map.has_key?(errors, :chat_message)
    end
  end

  describe "hardening — unclosed openers" do
    test "unclosed brace in 240 KB of prose returns within 1 s" do
      text = String.duplicate("{ word ", 40_000)

      {t, result} =
        :timer.tc(fn -> JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{}) end)

      assert {:error, {:json_parse_error, _, _}} = result
      assert t < 1_000_000
    end

    test "unclosed brackets and braces mixed still find the later balanced region" do
      text = String.duplicate("[ {", 5_000) <> ~s( {"chat_message": "hi"})

      assert {:ok, %BaseAgentOutputSchema{chat_message: "hi"}} =
               JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{})
    end
  end

  describe "hardening — size guard is not bypassed by prose extraction" do
    test "over-limit input surfaces :input_too_large at the top level without prose recovery" do
      # A 22-byte valid object embedded in prose; total ~81 bytes, well over the 30-byte limit.
      # Before the fix, extract_balanced recovers the embedded object (22 < 30) and returns
      # {:ok, _}, silently defeating the limit. After the fix, the guard short-circuits.
      embedded = ~s({"chat_message": "ok"})
      big = "Result: " <> embedded <> " " <> String.duplicate("x", 50)

      assert {:error, {:input_too_large, size, 30}} =
               JsonDeserializer.parse_and_validate(big, %MultiField{}, max_input_bytes: 30)

      assert size > 30
    end
  end
end
