defmodule Normandy.LLM.RequestResponseTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.Message
  alias Normandy.LLM.{Request, Response}

  test "a request needs model, messages and max_tokens" do
    assert_raise ArgumentError, ~r/the following keys must also be given.*:max_tokens/, fn ->
      struct!(Request, model: "m", messages: [])
    end
  end

  test "a request defaults the optional fields" do
    request = %Request{
      model: "m",
      messages: [%Message{role: "user", content: "hi"}],
      max_tokens: 10
    }

    assert %Request{
             system: nil,
             response_model: nil,
             temperature: nil,
             tools: [],
             mcp_servers: nil,
             task_budget_remaining: nil
           } = request
  end

  test "a response needs content and defaults the rest" do
    assert %Response{content: "x", stop_reason: nil, usage: nil, meta: %{}} =
             %Response{content: "x"}

    assert_raise ArgumentError, fn -> struct!(Response, []) end
  end

  test "a response accepts unrecognized provider stop reasons as strings" do
    assert %Response{content: "x", stop_reason: "some_new_reason"} =
             %Response{content: "x", stop_reason: "some_new_reason"}
  end

  describe "stop_reason/1" do
    @known [
      :end_turn,
      :tool_use,
      :max_tokens,
      :stop_sequence,
      :pause_turn,
      :refusal,
      :model_context_window_exceeded,
      :compaction
    ]

    test "pause_turn maps to its atom" do
      assert Response.stop_reason("pause_turn") == :pause_turn
    end

    test "every known reason's string maps to its atom; an atom passes through" do
      for reason <- @known do
        assert Response.stop_reason(Atom.to_string(reason)) == reason
        assert Response.stop_reason(reason) == reason
      end
    end

    test "an unknown string is returned unchanged and creates no atom" do
      fresh = "normandy_unknown_stop_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(fresh) end
      assert Response.stop_reason(fresh) == fresh
      assert_raise ArgumentError, fn -> String.to_existing_atom(fresh) end
    end
  end
end
