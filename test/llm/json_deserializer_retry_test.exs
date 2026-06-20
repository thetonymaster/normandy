defmodule Normandy.Test.RawRecoveryClient do
  @moduledoc false
  defstruct []
end

defimpl Normandy.Agents.Model, for: Normandy.Test.RawRecoveryClient do
  def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

  # Returns valid JSON as RAW TEXT only when the retry loop asks for raw output.
  # If raw: true is not threaded, this returns malformed text and recovery fails.
  def converse(_c, _m, _t, _mt, _msgs, _response_model, opts) do
    if Keyword.get(opts, :raw, false) do
      ~s({"chat_message": "recovered"})
    else
      "not json"
    end
  end
end

defmodule Normandy.Test.TupleRecoveryResponse do
  @moduledoc false
  defstruct chat_message: nil
end

defmodule Normandy.Test.TupleRecoveryClient do
  @moduledoc false
  defstruct []
end

defimpl Normandy.Agents.Model, for: Normandy.Test.TupleRecoveryClient do
  def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

  # Mirrors ClaudioAdapter's {struct, usage} return; the struct carries valid
  # JSON as its chat_message, which the retry loop must extract and re-parse.
  def converse(_c, _m, _t, _mt, _msgs, _response_model, _opts) do
    {%Normandy.Test.TupleRecoveryResponse{chat_message: ~s({"chat_message": "recovered"})},
     %{tokens: 1}}
  end
end

defmodule Normandy.LLM.JsonDeserializerRetryTest do
  use ExUnit.Case, async: false

  alias Normandy.LLM.JsonDeserializer
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.Components.Message

  @msgs [%Message{turn_id: "t", role: "system", content: "sys"}]

  test "retry recovers via a raw-text completion (proves raw: true is threaded)" do
    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               %Normandy.Test.RawRecoveryClient{},
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 1
             )
  end

  test "retry recovers when the client returns a {struct, usage} tuple" do
    assert {:ok, %MultiField{chat_message: "recovered"}} =
             JsonDeserializer.deserialize_with_retry(
               "not json",
               %MultiField{},
               %Normandy.Test.TupleRecoveryClient{},
               "mock-model",
               0.0,
               100,
               @msgs,
               max_retries: 1
             )
  end
end
