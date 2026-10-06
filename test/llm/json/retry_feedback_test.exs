defmodule Normandy.LLM.Json.RetryFeedbackTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.Message
  alias Normandy.LLM.Json.RetryFeedback
  alias Normandy.LLM.Json.TestFixtures.RequiredField
  alias Normandy.LLM.JsonDeserializer

  test "json_parse_error feedback contains the error and a correction instruction" do
    feedback =
      RetryFeedback.build(
        {:json_parse_error, :invalid, "oops"},
        "oops",
        %RequiredField{},
        Normandy.JSON
      )

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
        Normandy.JSON
      )

    assert feedback =~ "chat_message"
    assert feedback =~ "Required Schema"
  end

  test "augment_messages adds the feedback as a user message and leaves the system prompt alone" do
    messages = [
      %Message{turn_id: "t", role: "system", content: "base"},
      %Message{turn_id: "t", role: "user", content: "hi"}
    ]

    assert [^messages, [feedback]] =
             messages
             |> RetryFeedback.augment_messages("FEEDBACK")
             |> Enum.split(2)
             |> Tuple.to_list()

    assert %Message{role: "user", content: "FEEDBACK"} = feedback
  end

  test "augment_messages works with a block-list system prompt" do
    system = [%Normandy.Components.ContentBlock.Text{text: "base"}]
    messages = [%Message{turn_id: "t", role: "system", content: system}]

    assert [%Message{content: ^system}, %Message{role: "user", content: "FEEDBACK"}] =
             RetryFeedback.augment_messages(messages, "FEEDBACK")
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

  test "build/4 with Normandy.JSON includes the required schema section" do
    err = {:json_parse_error, :invalid, "oops"}
    assert RetryFeedback.build(err, "oops", %RequiredField{}, Normandy.JSON) =~ "Required Schema"
  end

  test "correction instructions are plain, with no shouting and no field-name example" do
    parse_feedback =
      RetryFeedback.build(
        {:json_parse_error, :invalid, "oops"},
        "oops",
        %RequiredField{},
        Normandy.JSON
      )

    {:error, {:validation_error, changeset, content}} =
      JsonDeserializer.parse_and_validate(~s({"count": 1}), %RequiredField{})

    validation_feedback =
      RetryFeedback.build(
        {:validation_error, changeset, content},
        content,
        %RequiredField{},
        Normandy.JSON
      )

    for feedback <- [parse_feedback, validation_feedback] do
      refute feedback =~ ~r/\bMUST\b|Do NOT|CORRECT|INCORRECT/
      refute feedback =~ "This is my response"
      assert feedback =~ "Respond with"
    end
  end

  test "any other failure gets the parse template and the schema, never an Elixir term" do
    too_large =
      RetryFeedback.build(
        {:input_too_large, 2_048, 1_024},
        ~s({"chat_message": "long"}),
        %RequiredField{},
        Normandy.JSON
      )

    assert too_large =~ "# RESPONSE FORMAT ERROR"
    assert too_large =~ "Your previous response could not be used as the answer."

    assert too_large =~
             "The response is 2048 bytes; the limit is 1024 bytes. Give a shorter answer."

    assert too_large =~ "## Required Schema"
    assert too_large =~ "Respond with a single JSON object"
    refute too_large =~ "input_too_large"

    not_object =
      RetryFeedback.build(
        {:unexpected_parse_result, "[1, 2]"},
        "[1, 2]",
        %RequiredField{},
        Normandy.JSON
      )

    assert not_object =~ "The response is valid JSON, but not a JSON object."
    refute not_object =~ "unexpected_parse_result"

    other = RetryFeedback.build({:some, :term}, "x", %RequiredField{}, Normandy.JSON)
    assert other =~ "The response does not match the required format."
    refute other =~ ":some"
  end

  test "a decode exception is shown as its message, never as a struct" do
    {:error, %Jason.DecodeError{} = exception} = Jason.decode("oops")

    feedback =
      RetryFeedback.build(
        {:json_parse_error, exception, "oops"},
        "oops",
        %RequiredField{},
        Normandy.JSON
      )

    assert feedback =~ "Invalid JSON: " <> Exception.message(exception)
    refute feedback =~ "Jason.DecodeError"
  end
end
