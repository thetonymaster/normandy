defmodule Normandy.LLM.OpenAICompatibleAdapterTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Model
  alias Normandy.Components.Message
  alias Normandy.LLM.OpenAICompatibleAdapter, as: Adapter

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
        Model.converse(client, "gpt-4o", 0.7, 1024, msgs, schema, [])

      assert resp.chat_message == "The answer is 42."
      assert usage == %{"total_tokens" => 10}
    end
  end

  describe "build_body/4 with unset sampling parameters" do
    alias Normandy.LLM.OpenAICompatibleAdapter, as: A

    test "nil temperature and max_tokens are left out (not sent as JSON null)" do
      body =
        A.build_body("m", nil, nil, [%Normandy.Components.Message{role: "user", content: "hi"}])

      refute Map.has_key?(body, "temperature")
      refute Map.has_key?(body, "max_tokens")
    end

    test "set values are sent" do
      body =
        A.build_body("m", 0.2, 64, [%Normandy.Components.Message{role: "user", content: "hi"}])

      assert body["temperature"] == 0.2
      assert body["max_tokens"] == 64
    end

    test "an agent built without temperature sends none on the wire (BaseAgent.run → converse)" do
      test_pid = self()

      adapter_fn = fn request ->
        send(test_pid, {:openai_body, request.body |> IO.iodata_to_binary() |> Jason.decode!()})

        {request,
         Req.Response.json(%{
           "choices" => [%{"message" => %{"content" => "ok"}}],
           "usage" => %{"total_tokens" => 1}
         })}
      end

      client = %A{
        api_key: "k",
        base_url: "https://example.test/v1",
        options: %{req_options: [adapter: adapter_fn]}
      }

      agent = BaseAgent.init(%{client: client, model: "gpt-4o"})
      BaseAgent.run(agent, "hi")

      assert_received {:openai_body, body}
      refute Map.has_key?(body, "temperature")
    end
  end

  describe "converse/7 failures" do
    @key "sk-openai-test-canary"

    defp failing_client(adapter_fn) do
      %Adapter{
        api_key: @key,
        base_url: "https://example.test/v1",
        options: %{req_options: [adapter: adapter_fn, retry: false]}
      }
    end

    defp call(client) do
      Model.converse(
        client,
        "gpt-4o",
        nil,
        1024,
        [%Message{role: "user", content: "hi"}],
        %Normandy.Agents.BaseAgentOutputSchema{},
        []
      )
    end

    for {status, type, retryable?} <- [
          {401, :authentication, false},
          {403, :permission, false},
          {404, :not_found, false},
          {422, :invalid_request, false},
          {429, :rate_limit, true},
          {408, :server, true},
          {500, :server, true},
          {503, :server, true}
        ] do
      test "HTTP #{status} -> #{type}, retryable?: #{retryable?}" do
        adapter_fn = fn request ->
          {request,
           Req.Response.new(
             status: unquote(status),
             body: %{"error" => %{"message" => "provider says no"}}
           )}
        end

        assert {:error, %Normandy.LLMError{} = e} = call(failing_client(adapter_fn))
        assert e.type == unquote(type)
        assert e.status == unquote(status)
        assert e.retryable? == unquote(retryable?)
        assert e.message =~ "provider says no"
        refute inspect(e) =~ @key
      end
    end

    test "a body without an error message falls back to HTTP <status>" do
      adapter_fn = fn request -> {request, Req.Response.new(status: 502, body: "")} end

      assert {:error, %Normandy.LLMError{message: "LLM call failed: server (502): HTTP 502"}} =
               call(failing_client(adapter_fn))
    end

    test "a transport error -> :transport, retryable" do
      adapter_fn = fn request -> {request, %Req.TransportError{reason: :timeout}} end

      assert {:error, %Normandy.LLMError{type: :transport, retryable?: true, status: nil}} =
               call(failing_client(adapter_fn))
    end
  end
end
