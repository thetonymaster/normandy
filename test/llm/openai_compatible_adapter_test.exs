defmodule Normandy.LLM.OpenAICompatibleAdapterTest do
  use ExUnit.Case, async: true
  alias Normandy.LLM.OpenAICompatibleAdapter, as: Adapter
  alias Normandy.Components.Message

  describe "convert_messages/1" do
    test "maps Normandy messages to OpenAI role/content maps" do
      msgs = [
        %Message{role: "system", content: "You are helpful."},
        %Message{role: "user", content: "Hi"}
      ]

      assert Adapter.convert_messages(msgs) == [
               %{"role" => "system", "content" => "You are helpful."},
               %{"role" => "user", "content" => "Hi"}
             ]
    end

    test "raises on non-string content (text-only v1)" do
      assert_raise ArgumentError, fn ->
        Adapter.convert_messages([%Message{role: "user", content: [%{}]}])
      end
    end
  end

  describe "extract_text/1" do
    test "pulls assistant content from a chat-completions body" do
      body = %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "hello world"}}]
      }

      assert Adapter.extract_text(body) == "hello world"
    end

    test "returns empty string when no choices" do
      assert Adapter.extract_text(%{"choices" => []}) == ""
    end
  end

  describe "converse/7 (stubbed transport)" do
    test "returns response_model with prose in :chat_message" do
      # Stub Req via the adapter option carried in options[:req_options].
      # Using :adapter (not :plug) because plug dep is not installed.
      adapter_fn = fn request ->
        response =
          Req.Response.json(%{
            "choices" => [%{"message" => %{"content" => "The answer is 42."}}],
            "usage" => %{"total_tokens" => 10}
          })

        {request, response}
      end

      client = %Adapter{
        api_key: "test-key",
        base_url: "https://example.test/v1",
        options: %{req_options: [adapter: adapter_fn]}
      }

      # Default agent output schema — confirmed: Normandy.Agents.BaseAgentOutputSchema
      schema = %Normandy.Agents.BaseAgentOutputSchema{}
      msgs = [%Message{role: "user", content: "What is the answer?"}]

      {resp, usage} =
        Normandy.Agents.Model.converse(client, "gpt-4o", 0.7, 1024, msgs, schema, [])

      assert resp.chat_message == "The answer is 42."
      assert usage == %{"total_tokens" => 10}
    end
  end
end
