defmodule Normandy.LLMErrorTest do
  use ExUnit.Case, async: true

  alias Normandy.LLMError

  describe "new/1" do
    test "builds the message from type, status and detail" do
      e = LLMError.new(type: :rate_limit, status: 429, retryable?: true, detail: "slow down")

      assert %LLMError{type: :rate_limit, status: 429, retryable?: true} = e
      assert e.message == "LLM call failed: rate_limit (429): slow down"
      assert Exception.message(e) == e.message
    end

    test "omits the status and detail parts when absent" do
      assert LLMError.new(type: :transport, retryable?: true).message ==
               "LLM call failed: transport"
    end

    test "keeps the original error in :reason" do
      assert LLMError.new(type: :unknown, retryable?: false, reason: {:boom, 1}).reason ==
               {:boom, 1}
    end

    test "rejects an unknown type, naming the value" do
      assert_raise ArgumentError, ~r/unknown :type :nope/, fn ->
        LLMError.new(type: :nope, retryable?: false)
      end
    end

    test "rejects a non-boolean retryable?" do
      assert_raise ArgumentError, ~r/:retryable\? must be a boolean, got: :yes/, fn ->
        LLMError.new(type: :server, retryable?: :yes)
      end
    end

    test ":unsupported is a known type" do
      assert %Normandy.LLMError{type: :unsupported, retryable?: false} =
               Normandy.LLMError.new(
                 type: :unsupported,
                 retryable?: false,
                 detail: "no streaming"
               )
    end
  end

  describe "wrap/1" do
    test "passes an LLMError through unchanged" do
      e = LLMError.new(type: :server, status: 500, retryable?: true)
      assert LLMError.wrap(e) == e
    end

    test "wraps any other term as :unknown without putting it in the message" do
      e = LLMError.wrap({:secret_ish, "sk-ant-canary"})

      assert %LLMError{type: :unknown, retryable?: false, reason: {:secret_ish, "sk-ant-canary"}} =
               e

      assert e.message == "LLM call failed: unknown"
    end
  end
end
