defmodule Normandy.LLM.Json.RetryFeedbackTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.Components.Message
  alias Normandy.LLM.Json.TestFixtures.RequiredField

  test "json_parse_error feedback contains the error and a correction instruction" do
    feedback =
      RetryFeedback.build({:json_parse_error, :invalid, "oops"}, "oops", %RequiredField{})

    assert feedback =~ "JSON"
    assert feedback =~ "valid JSON"
  end

  test "validation_error feedback names the offending field" do
    {:error, {:validation_error, changeset, content}} =
      Normandy.LLM.JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

    feedback =
      RetryFeedback.build({:validation_error, changeset, content}, content, %RequiredField{})

    assert feedback =~ "chat_message"
    assert feedback =~ "Required Schema"
  end

  test "augment_messages appends feedback to the system message only" do
    messages = [
      %Message{turn_id: "t", role: "system", content: "base"},
      %Message{turn_id: "t", role: "user", content: "hi"}
    ]

    [sys, user] = RetryFeedback.augment_messages(messages, "FEEDBACK")
    assert sys.content =~ "base"
    assert sys.content =~ "FEEDBACK"
    assert user.content == "hi"
  end
end
