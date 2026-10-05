defmodule Normandy.LLM.JsonDeserializerRetryTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.Message
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.JsonDeserializer
  alias Normandy.LLM.{Request, Response}
  alias Normandy.Test.StubClient

  @request %Request{
    model: "mock-model",
    temperature: 0.0,
    max_tokens: 100,
    messages: [%Message{turn_id: "t", role: "user", content: "hi"}],
    response_model: %MultiField{}
  }

  defmodule TupleRecoveryResponse do
    @moduledoc false
    defstruct chat_message: nil
  end

  test "an LLM error during a parse retry is returned, with no further attempts" do
    error = Normandy.LLMError.new(type: :overloaded, status: 529, retryable?: true)
    client = %StubClient{notify: self(), reply: fn _ -> {:error, error} end}

    assert {:error, %Normandy.LLMError{type: :overloaded}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               client,
               @request,
               max_retries: 2
             )

    assert_received {:converse, _, _}
    refute_received {:converse, _, _}
  end

  test "a retry asks for text with response_model: nil" do
    # Valid JSON comes back as text only when the retry asks for text.
    client = %StubClient{
      notify: self(),
      reply: fn
        nil -> ~s({"chat_message": "recovered"})
        _response_model -> "not json"
      end
    }

    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               client,
               @request,
               max_retries: 1
             )

    assert_received {:converse, %Request{response_model: nil, messages: messages}, opts}
    assert opts[:request_kind] == :json_retry

    # The retry resends the original conversation plus the error feedback.
    assert [%Message{content: "hi"}, %Message{role: "user"}] = messages
  end

  test "retry recovers when the client returns a struct with usage" do
    # The struct carries valid JSON as its chat_message, which the retry must re-parse.
    client = %StubClient{
      reply: fn _ ->
        {:ok,
         %Response{
           content: %TupleRecoveryResponse{chat_message: ~s({"chat_message": "recovered"})},
           usage: %{tokens: 1}
         }}
      end
    }

    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               client,
               @request,
               max_retries: 1
             )
  end
end
