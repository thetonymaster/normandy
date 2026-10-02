defmodule Normandy.LLM.JsonDeserializerRetryTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.Message
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.JsonDeserializer
  alias Normandy.Test.StubClient

  @msgs [%Message{turn_id: "t", role: "system", content: "sys"}]

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
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 2
             )

    assert_received {:converse, _, _}
    refute_received {:converse, _, _}
  end

  test "retry recovers via a raw-text completion (proves raw: true is threaded)" do
    # Valid JSON comes back as raw text only when the retry asks for raw output.
    client = %StubClient{
      reply: fn _, opts ->
        if Keyword.get(opts, :raw, false), do: ~s({"chat_message": "recovered"}), else: "not json"
      end
    }

    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               client,
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 1
             )
  end

  test "retry recovers when the client returns a {struct, usage} tuple" do
    # The struct carries valid JSON as its chat_message, which the retry must re-parse.
    client = %StubClient{
      reply: fn _ ->
        {%TupleRecoveryResponse{chat_message: ~s({"chat_message": "recovered"})}, %{tokens: 1}}
      end
    }

    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               client,
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 1
             )
  end
end
