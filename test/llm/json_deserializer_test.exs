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

  defmodule RecoveryFixture do
    @moduledoc false
    use Normandy.Schema

    io_schema "fixture for truncated-string recovery tests" do
      field(:page_text, :string, description: "transcribed text", default: "")
      field(:facts, {:array, :string}, description: "facts", default: [])
    end
  end
end

defmodule Normandy.LLM.JsonDeserializerTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.JsonDeserializer
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.LLM.JsonDeserializerTest.WrapperFixtures.MultiField
  alias Normandy.LLM.JsonDeserializerTest.WrapperFixtures.RequiredField
  alias Normandy.LLM.JsonDeserializerTest.WrapperFixtures.RecoveryFixture

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

  describe "parse_and_validate/3 — :recover_truncated_strings option" do
    test "recovers a top-level string field truncated at a \\n-escape runaway" do
      # Bytes: { " p a g e _ t e x t " :   " h e l l o   w o r l d \ n \ n \ n \ n
      # No closing " and no closing }. The trailing \n sequences are the model
      # runaway; recovery should truncate at the last position before the runaway,
      # close the string, and close the object.
      truncated = ~s({"page_text": "hello world\\n\\n\\n\\n)

      assert {:ok, %RecoveryFixture{page_text: "hello world"}} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Poison,
                 recover_truncated_strings: true
               )
    end

    test "default-off: truncated content returns the original parse error" do
      truncated = ~s({"page_text": "hello\\n\\n\\n)

      assert {:error, {:json_parse_error, _, _}} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Poison
               )
    end

    test "explicit false: truncated content returns the original parse error" do
      truncated = ~s({"page_text": "hello\\n\\n\\n)

      assert {:error, {:json_parse_error, _, _}} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Poison,
                 recover_truncated_strings: false
               )
    end

    test "declines recovery when truncation is inside a nested object" do
      # Truncation is in an inner object's string value (offerings[0].name).
      # opener_depth at EOF is 3 (outer object, array, inner object) — recovery
      # must not fire here, because manufacturing a closer would produce a
      # half-truthful inner record rather than an empty top-level field.
      truncated = ~s({"offerings": [{"name": "Paq)

      assert {:error, {:json_parse_error, _, _}} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Poison,
                 recover_truncated_strings: true
               )
    end

    test "declines recovery when truncation is inside a top-level array element string" do
      # Same shape: the inner string lives at depth 2 (object → array → string).
      truncated = ~s({"facts": ["fact one", "fact tw)

      assert {:error, {:json_parse_error, _, _}} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Poison,
                 recover_truncated_strings: true
               )
    end

    test "recovers an immediately-truncated empty top-level string to \"\"" do
      # The model emitted the opening quote of page_text and ran out of tokens
      # right there. Recovery should produce an empty string for page_text
      # rather than giving up.
      truncated = ~s({"page_text": ")

      assert {:ok, %RecoveryFixture{page_text: ""}} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Poison,
                 recover_truncated_strings: true
               )
    end

    test "valid JSON with recover_truncated_strings: true behaves exactly as without" do
      valid = ~s({"page_text": "complete", "facts": ["a", "b"]})

      with_flag =
        JsonDeserializer.parse_and_validate(
          valid,
          %RecoveryFixture{},
          adapter: Poison,
          recover_truncated_strings: true
        )

      without_flag =
        JsonDeserializer.parse_and_validate(
          valid,
          %RecoveryFixture{},
          adapter: Poison
        )

      assert {:ok, %RecoveryFixture{page_text: "complete", facts: ["a", "b"]}} = with_flag
      assert with_flag == without_flag
    end

    test "recovers the page_text-last shape from the captured Nemotron-VL fixture" do
      # Mirrors the captured fixture: facts populated, page_text opens, model
      # emits some real prose, then runs away with \n escapes and EOFs without
      # closing the string or the outer object. Recovery must:
      #   * keep facts populated;
      #   * truncate page_text at the last non-\n-escape position;
      #   * close the string and the outer object.
      truncated =
        ~s({"facts": ["Mixology", "Premium Bar"], "page_text": "NATIVA MIXOLOGY\\n\\n\\n\\n\\n\\n\\n\\n)

      assert {:ok,
              %RecoveryFixture{
                page_text: "NATIVA MIXOLOGY",
                facts: ["Mixology", "Premium Bar"]
              }} =
               JsonDeserializer.parse_and_validate(
                 truncated,
                 %RecoveryFixture{},
                 adapter: Poison,
                 recover_truncated_strings: true
               )
    end

    test "emits [:normandy, :json_deserializer, :recovery] on successful recovery" do
      handler_id = "recovery-telemetry-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:normandy, :json_deserializer, :recovery],
        fn name, measurements, metadata, %{test_pid: pid} ->
          send(pid, {:telemetry, name, measurements, metadata})
        end,
        %{test_pid: test_pid}
      )

      try do
        truncated = ~s({"page_text": "hello world\\n\\n\\n)

        {:ok, _} =
          JsonDeserializer.parse_and_validate(
            truncated,
            %RecoveryFixture{},
            adapter: Poison,
            recover_truncated_strings: true
          )

        assert_received {:telemetry, [:normandy, :json_deserializer, :recovery], %{recovered: 1},
                         %{
                           strategy: :truncated_string,
                           byte_size_before: before,
                           byte_size_after: after_
                         }}

        assert is_integer(before) and before > 0
        assert is_integer(after_) and after_ > 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "does not emit recovery telemetry when recovery did not fire" do
      handler_id = "recovery-telemetry-negative-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:normandy, :json_deserializer, :recovery],
        fn name, measurements, metadata, %{test_pid: pid} ->
          send(pid, {:telemetry, name, measurements, metadata})
        end,
        %{test_pid: test_pid}
      )

      try do
        valid = ~s({"page_text": "complete"})

        {:ok, _} =
          JsonDeserializer.parse_and_validate(
            valid,
            %RecoveryFixture{},
            adapter: Poison,
            recover_truncated_strings: true
          )

        refute_received {:telemetry, _, _, _}
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
