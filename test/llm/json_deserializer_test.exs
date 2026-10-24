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
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end

    test "wrapper shape with matching inner keys is unwrapped" do
      content = ~s({"name": "extract", "arguments": {"chat_message": "hello", "count": 7}})

      assert {:ok, %MultiField{chat_message: "hello", count: 7}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end

    test "wrapper shape with non-matching inner keys returns the empty struct" do
      content = ~s({"name": "extract", "arguments": {"unrelated": "data"}})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end

    test "no arguments key and empty cast preserves current behavior" do
      content = ~s({"name": "extract"})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end

    test "non-map arguments value falls back to empty struct (no crash)" do
      string_args = ~s({"name": "extract", "arguments": "not a map"})
      list_args = ~s({"name": "extract", "arguments": [1, 2, 3]})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(string_args, %MultiField{})

      assert {:ok, %MultiField{chat_message: nil, count: 0}} =
               JsonDeserializer.parse_and_validate(list_args, %MultiField{})
    end

    test "required-field validation still fires when neither outer nor inner supplies it" do
      content = ~s({"name": "extract", "arguments": {"unrelated": "data"}})

      assert {:error, {:validation_error, _changeset, _content}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{})
    end

    test "wrapper supplies required field only in inner — unwrap still succeeds" do
      content = ~s({"name": "extract", "arguments": {"chat_message": "hi"}})

      assert {:ok, %RequiredField{chat_message: "hi"}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{})
    end

    test "inner cast error on a permitted key is surfaced, not masked as empty success" do
      content = ~s({"name": "extract", "arguments": {"count": "not_a_number"}})

      assert {:error, {:validation_error, _changeset, _content}} =
               JsonDeserializer.parse_and_validate(content, %MultiField{})
    end
  end

  describe "removed options" do
    test ":recover_truncated_strings is refused, naming the option" do
      assert_raise ArgumentError,
                   ~r/parse_and_validate\/3: unknown option :recover_truncated_strings/,
                   fn ->
                     JsonDeserializer.parse_and_validate(
                       ~s({"page_text": "hi),
                       %RecoveryFixture{},
                       recover_truncated_strings: true
                     )
                   end
    end

    test ":adapter is refused, naming the option" do
      assert_raise ArgumentError, ~r/parse_and_validate\/3: unknown option :adapter/, fn ->
        JsonDeserializer.parse_and_validate(~s({"chat_message": "hi"}), %MultiField{},
          adapter: Jason
        )
      end

      assert_raise ArgumentError, ~r/deserialize_with_retry\/5: unknown option :adapter/, fn ->
        JsonDeserializer.deserialize_with_retry("x", %MultiField{}, nil, @request, adapter: Jason)
      end
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

    test "an object nested deep in one large region still binds" do
      # Each level decoded and failed binding, costing its whole size: past 8 levels of
      # one 20 KB payload the budget ran out before the object that binds.
      inner = ~s({"chat_message": "deep", "note": "#{String.duplicate("x", 20_000)}"})
      doc = Enum.reduce(1..12, inner, fn i, acc -> ~s({"level#{i}": #{acc}}) end)

      assert {:ok, %RequiredField{chat_message: "deep"}} =
               JsonDeserializer.parse_and_validate("Here: " <> doc, %RequiredField{})
    end

    test "inside a region, the first object in the text that binds wins" do
      content = ~s(Result: {"z": {"chat_message": "first"}, "a": {"chat_message": "second"}})

      assert {:ok, %RequiredField{chat_message: "first"}} =
               JsonDeserializer.parse_and_validate(content, %RequiredField{})
    end

    test "an object inside an array region binds" do
      content = ~s(Items: [1, {"count": 2}, {"chat_message": "in a list"}])

      assert {:ok, %RequiredField{chat_message: "in a list"}} =
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
    # The quadratic versions of these inputs took 30-60 s; linear work takes well under 1 s
    # locally. 5 s keeps the check meaningful on a slow, shared CI runner.
    @linear_budget_us 5_000_000

    test "unclosed brace in 240 KB of prose returns within the linear budget" do
      text = String.duplicate("{ word ", 40_000)

      {t, result} =
        :timer.tc(fn -> JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{}) end)

      assert {:error, {:json_parse_error, _, _}} = result
      assert t < @linear_budget_us
    end

    test "repeated unclosed brace + escaped quote in 240 KB returns within the linear budget" do
      text = String.duplicate("{ \\\" ", 48_000)

      {t, result} =
        :timer.tc(fn -> JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{}) end)

      assert {:error, {:json_parse_error, _, _}} = result
      assert t < @linear_budget_us
    end

    test "an escaped-quote tail before a valid object still finds the object" do
      text = String.duplicate("{ \\\" ", 5_000) <> ~s(\n{"chat_message": "hi"})

      assert {:ok, %BaseAgentOutputSchema{chat_message: "hi"}} =
               JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{})
    end

    for lines <- [100, 7_700] do
      test "an answer after C code that prints escaped JSON is found (#{lines} lines)" do
        line = ~S|  printf("{\"id\": %d}\n", x);| <> "\n"
        text = "int main() {\n" <> String.duplicate(line, unquote(lines)) <> "}\n"
        text = text <> ~s({"chat_message": "done"})

        {t, result} =
          :timer.tc(fn -> JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{}) end)

        assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} = result
        assert t < @linear_budget_us
      end
    end

    test "240 KB of deeply nested brackets returns within the linear budget" do
      text = String.duplicate("[", 120_000) <> String.duplicate("]", 120_000) <> " x"

      {t, result} =
        :timer.tc(fn -> JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{}) end)

      assert {:error, {:json_parse_error, _, _}} = result
      assert t < @linear_budget_us
    end

    test "one stray opener before 200 KB of prose parses in a bounded heap" do
      # The stray's scan reads to the end. A map entry per byte it read took a 6-12M-word
      # heap here; marked states only take under 1.5M (investigations/json-region-240kb.md).
      unit = "Here is what I found. ```elixir\nfn x -> %{a: x, b: [x, x]} end\n```\n"

      text =
        "Use { to open a block. " <>
          String.duplicate(unit, 1_600) <>
          ~s({"chat_message": "42"}) <> String.duplicate(unit, 1_600)

      parent = self()

      {_pid, ref} =
        :erlang.spawn_opt(
          fn ->
            send(
              parent,
              {:parsed, JsonDeserializer.parse_and_validate(text, %BaseAgentOutputSchema{})}
            )
          end,
          [:monitor, max_heap_size: %{size: 3_000_000, kill: true, error_logger: false}]
        )

      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5_000
      assert_received {:parsed, {:ok, %BaseAgentOutputSchema{chat_message: "42"}}}
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
