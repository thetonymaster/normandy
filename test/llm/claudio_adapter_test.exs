defmodule NormandyTest.LLM.ClaudioAdapterTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.Agents.BaseAgentOutputSchema

  describe "ClaudioAdapter schema" do
    test "creates adapter with required fields" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        options: %{timeout: 60_000}
      }

      assert adapter.api_key == "test-key"
      assert adapter.options.timeout == 60_000
      assert adapter.base_url == nil
    end

    test "creates adapter with custom base_url" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        base_url: "https://custom.api.com"
      }

      assert adapter.base_url == "https://custom.api.com"
    end
  end

  describe "Model protocol implementation" do
    test "implements completitions/6 (legacy compatibility)" do
      adapter = %ClaudioAdapter{api_key: "test-key"}
      response_model = %BaseAgentOutputSchema{}

      result =
        Normandy.Agents.Model.completitions(
          adapter,
          "claude-3",
          0.7,
          1024,
          "test",
          response_model
        )

      # Should return the response_model unchanged for legacy API
      assert result == response_model
    end

    # Note: Testing actual converse/7 would require mocking Claudio.Client
    # and Claudio.Messages.create, which is beyond this basic test.
    # In integration tests, you would mock these dependencies.
  end

  describe "ClaudioAdapter integration" do
    test "can be used as a client in BaseAgent config" do
      adapter = %ClaudioAdapter{
        api_key: "test-key",
        options: %{
          timeout: 60_000,
          enable_caching: true
        }
      }

      config = %{
        client: adapter,
        model: "claude-haiku-4-5-20251001",
        temperature: 0.7
      }

      agent = Normandy.Agents.BaseAgent.init(config)

      assert agent.client == adapter
      assert agent.model == "claude-haiku-4-5-20251001"
      assert agent.temperature == 0.7
    end
  end

  describe "Inspect protocol" do
    test "does not leak api_key in inspect output" do
      adapter = %ClaudioAdapter{api_key: "sk-ant-secret-leak-canary"}
      output = inspect(adapter)

      refute output =~ "sk-ant-secret-leak-canary"
      refute output =~ "api_key"
    end

    test "still allows direct api_key access after redaction" do
      adapter = %ClaudioAdapter{api_key: "sk-secret"}

      assert adapter.api_key == "sk-secret"
      assert Map.get(adapter, :api_key) == "sk-secret"
      assert match?(%ClaudioAdapter{api_key: "sk-secret"}, adapter)
    end
  end

  describe "on_parse_failure policy" do
    test "defaults to :fallback" do
      assert :fallback = Normandy.LLM.ClaudioAdapter.__on_parse_failure_policy__(%{})
    end

    test "honors a per-call override" do
      assert :error =
               Normandy.LLM.ClaudioAdapter.__on_parse_failure_policy__(%{
                 on_parse_failure: :error
               })
    end
  end

  describe "raw completion mapping" do
    test "__raw_completion__ maps a successful Claudio response to {content, usage}" do
      response = %{content: [%{type: :text, text: "hello"}], usage: %{input_tokens: 5}}
      assert {"hello", %{input_tokens: 5}} = ClaudioAdapter.__raw_completion__({:ok, response})
    end

    test "__raw_completion__ joins multiple text blocks and ignores non-text blocks" do
      response = %{
        content: [%{type: :text, text: "a"}, %{type: :tool_use}, %{type: :text, text: "b"}]
      }

      assert {"a\nb", nil} = ClaudioAdapter.__raw_completion__({:ok, response})
    end

    test "__raw_completion__ passes a Claudio API error straight through" do
      assert {:error, :boom} = ClaudioAdapter.__raw_completion__({:error, :boom})
    end
  end

  describe "apply_parse_failure/4" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    test ":fallback policy with binary content returns schema with chat_message set" do
      result =
        ClaudioAdapter.apply_parse_failure(%MultiField{}, "raw text", :some_reason, %{
          on_parse_failure: :fallback
        })

      assert %MultiField{chat_message: "raw text"} = result
    end

    test ":fallback policy with non-binary content returns the schema unchanged" do
      result =
        ClaudioAdapter.apply_parse_failure(%MultiField{}, nil, :some_reason, %{
          on_parse_failure: :fallback
        })

      assert %MultiField{chat_message: nil} = result
    end

    test ":error policy returns {:error, reason}" do
      assert {:error, :some_reason} =
               ClaudioAdapter.apply_parse_failure(%MultiField{}, "raw", :some_reason, %{
                 on_parse_failure: :error
               })
    end
  end

  describe "structured-vs-legacy routing decision (__structured_schema_for__/3)" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    defp routing_client, do: %Normandy.LLM.ClaudioAdapter{api_key: "k", options: %{}}

    test "uses structured outputs for a compatible schema with no tools" do
      assert {:ok, _schema} =
               ClaudioAdapter.__structured_schema_for__(routing_client(), %MultiField{}, [])
    end

    test "skips structured outputs when tools are present (tool_use needs the legacy loop)" do
      assert :skip =
               ClaudioAdapter.__structured_schema_for__(
                 routing_client(),
                 %MultiField{},
                 tools: [%{name: "lookup"}]
               )
    end
  end

  describe "structured response interpretation" do
    alias Normandy.LLM.Json.TestFixtures.MultiField

    defp text_response(stop_reason, text) do
      %{stop_reason: stop_reason, content: [%{type: :text, text: text}], usage: %{}}
    end

    test "normal stop with valid JSON decodes and binds to the schema" do
      resp = text_response(:end_turn, ~s({"chat_message": "hi", "count": 2}))

      assert %MultiField{chat_message: "hi", count: 2} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "refusal routes to the parse-failure policy (default :fallback)" do
      resp = text_response(:refusal, "I can't help with that.")

      assert %MultiField{chat_message: "I can't help with that."} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "max_tokens routes to the parse-failure policy" do
      resp = text_response(:max_tokens, ~s({"chat_message": "trunca))

      assert %MultiField{chat_message: ~s({"chat_message": "trunca)} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{})
    end

    test "non-conforming content under :error policy returns an error tuple" do
      resp = text_response(:refusal, "nope")

      assert {:error, {:structured_output_incomplete, :refusal}} =
               ClaudioAdapter.__handle_structured_response__(resp, %MultiField{}, %{
                 on_parse_failure: :error
               })
    end
  end
end
