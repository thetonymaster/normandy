defmodule Normandy.LLM.CallStopReasonTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.LLM.{Call, Request, Response}
  alias Normandy.LLMError
  alias Normandy.Test.StubClient

  @usage %{"input_tokens" => 10, "output_tokens" => 64}

  defp response(stop_reason),
    do: %Response{content: "cut off mid-sent", stop_reason: stop_reason, usage: @usage}

  describe "check_stop_reason/1" do
    test "max_tokens is a :max_tokens LLMError that keeps the billed usage and no model text" do
      assert {:error, %LLMError{} = error} = Call.check_stop_reason(response(:max_tokens))

      assert error.type == :max_tokens
      assert error.retryable? == false
      assert error.status == nil
      assert error.reason == {:stop_reason, :max_tokens}
      assert error.usage == @usage
      assert error.usage_counts.output_tokens == 64

      assert error.message ==
               "LLM call failed: max_tokens: the response stopped at max_tokens before it " <>
                 "was complete; raise the agent's max_tokens or ask for a shorter answer"

      refute inspect(error) =~ "cut off mid-sent"
    end

    test "model_context_window_exceeded is a :max_tokens LLMError whose detail names it" do
      assert {:error, %LLMError{type: :max_tokens, reason: reason, message: message}} =
               Call.check_stop_reason(response(:model_context_window_exceeded))

      assert reason == {:stop_reason, :model_context_window_exceeded}

      assert message ==
               "LLM call failed: max_tokens: the response stopped at " <>
                 "model_context_window_exceeded: the conversation filled the model's " <>
                 "context window; compact or shorten the history"
    end

    test "refusal is a :refusal LLMError" do
      assert {:error, %LLMError{type: :refusal, retryable?: false} = error} =
               Call.check_stop_reason(response(:refusal))

      assert error.reason == {:stop_reason, :refusal}

      assert error.message ==
               "LLM call failed: refusal: the model declined to answer (stop_reason refusal)"
    end

    test "the streamed string form is checked like the atom" do
      assert {:error, %LLMError{type: :max_tokens}} =
               Call.check_stop_reason(%{stop_reason: "max_tokens", usage: nil})

      assert {:error, %LLMError{type: :refusal, usage: nil}} =
               Call.check_stop_reason(%{stop_reason: "refusal"})
    end

    test "a complete or unknown stop reason passes the response through unchanged" do
      for reason <- [:end_turn, :tool_use, :stop_sequence, :pause_turn, nil, "a_future_reason"] do
        resp = response(reason)
        assert Call.check_stop_reason(resp) == {:ok, resp}
      end
    end
  end

  describe "stop_reason/1" do
    test "maps the API's strings onto Response's atoms and leaves others as strings" do
      assert Call.stop_reason("max_tokens") == :max_tokens
      assert Call.stop_reason("model_context_window_exceeded") == :model_context_window_exceeded
      assert Call.stop_reason("end_turn") == :end_turn
      assert Call.stop_reason("a_future_reason") == "a_future_reason"
      assert Call.stop_reason(:refusal) == :refusal
      assert Call.stop_reason(nil) == nil
    end
  end

  describe "converse/3" do
    test "an adapter's {:ok, response} cut off at max_tokens becomes the error" do
      client = %StubClient{
        reply: fn rm ->
          {:ok,
           %Response{
             content: %{rm | chat_message: "partial"},
             stop_reason: :max_tokens,
             usage: @usage
           }}
        end
      }

      request = %Request{
        model: "m",
        max_tokens: 8,
        messages: [],
        response_model: %BaseAgentOutputSchema{}
      }

      assert {:error, %LLMError{type: :max_tokens, usage: @usage}} =
               Call.converse(client, request, [])
    end
  end
end
