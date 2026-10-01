defmodule Normandy.LLM.Json.RetryFeedbackTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.Message
  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.LLM.Json.TestFixtures.RequiredField
  alias Normandy.LLM.JsonDeserializer

  test "json_parse_error feedback contains the error and a correction instruction" do
    feedback =
      RetryFeedback.build({:json_parse_error, :invalid, "oops"}, "oops", %RequiredField{}, Poison)

    assert feedback =~ "JSON"
    assert feedback =~ "valid JSON"
  end

  test "validation_error feedback names the offending field" do
    {:error, {:validation_error, changeset, content}} =
      JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

    feedback =
      RetryFeedback.build(
        {:validation_error, changeset, content},
        content,
        %RequiredField{},
        Poison
      )

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

  defmodule FakeAdapter do
    def encode!(_term, _opts), do: "<<ENCODED-BY-FAKE>>"
  end

  test "build/4 encodes the schema via the injected adapter" do
    feedback =
      RetryFeedback.build(
        {:json_parse_error, :invalid, "oops"},
        "oops",
        %RequiredField{},
        FakeAdapter
      )

    assert feedback =~ "<<ENCODED-BY-FAKE>>"
  end

  test "build/4 with Poison includes the required schema section" do
    err = {:json_parse_error, :invalid, "oops"}
    assert RetryFeedback.build(err, "oops", %RequiredField{}, Poison) =~ "Required Schema"
  end

  test "correction instructions are plain, with no shouting and no field-name example" do
    parse_feedback =
      RetryFeedback.build({:json_parse_error, :invalid, "oops"}, "oops", %RequiredField{}, Poison)

    {:error, {:validation_error, changeset, content}} =
      JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

    validation_feedback =
      RetryFeedback.build(
        {:validation_error, changeset, content},
        content,
        %RequiredField{},
        Poison
      )

    for feedback <- [parse_feedback, validation_feedback] do
      refute feedback =~ ~r/\bMUST\b|Do NOT|CORRECT|INCORRECT/
      refute feedback =~ "This is my response"
      assert feedback =~ "Respond with"
    end
  end
end
