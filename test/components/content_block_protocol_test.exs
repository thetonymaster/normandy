defmodule Normandy.Components.ContentBlockProtocolTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.ContentBlock
  alias Normandy.Components.ContentBlock.{Document, Image, Protocol, Text}
  alias Normandy.Components.Message
  alias Normandy.Context.{Summarizer, TokenEstimate}

  defmodule NotABlock do
    defstruct [:x]
  end

  # A third-party block: one defimpl is all a new block type needs.
  defmodule AudioBlock do
    defstruct [:id]

    defimpl Normandy.Components.ContentBlock.Protocol do
      def to_claudio(%{id: id}), do: %{"type" => "audio", "id" => id}
      def estimate_tokens(_), do: 700
      def label(_), do: "[audio]"
    end
  end

  defmodule RecordingClient do
    defstruct [:notify]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:request, request.messages})

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: "summary"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  @adapter Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter

  test "to_claudio/1 gives the Anthropic maps" do
    assert Protocol.to_claudio(Text.new("hi") |> Text.with_cache()) ==
             %{"type" => "text", "text" => "hi", "cache_control" => %{"type" => "ephemeral"}}

    assert Protocol.to_claudio(Image.new_base64("QQ==", "image/png")) ==
             %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "QQ=="}
             }

    assert Protocol.to_claudio(Image.new_url("https://x/y.png")) ==
             %{"type" => "image", "source" => %{"type" => "url", "url" => "https://x/y.png"}}

    assert Protocol.to_claudio(Document.new_file("file_1")) ==
             %{"type" => "document", "source" => %{"type" => "file", "file_id" => "file_1"}}
  end

  test "estimate_tokens/1 and label/1" do
    assert Protocol.estimate_tokens(Text.new(String.duplicate("a", 40))) == 10
    assert Protocol.estimate_tokens(Image.new_url("u")) == ContentBlock.image_tokens()
    assert Protocol.estimate_tokens(Document.new_file("f")) == ContentBlock.document_tokens()
    assert Protocol.label(Text.new("hello")) == "hello"
    assert Protocol.label(Image.new_url("u")) == "[image]"
    assert Protocol.label(Document.new_file("f")) == "[document]"
  end

  test "block?/1 is true for implementing structs only" do
    assert ContentBlock.block?(Text.new("x"))
    assert ContentBlock.block?(%AudioBlock{id: "a"})
    refute ContentBlock.block?(%NotABlock{})
    refute ContentBlock.block?(%{"type" => "text"})
    refute ContentBlock.block?("text")
  end

  describe "a third-party block" do
    test "is encoded by the adapter, alone and in a list" do
      block = %AudioBlock{id: "a1"}
      wire = %{"type" => "audio", "id" => "a1"}

      for content <- [block, [block]] do
        req =
          @adapter.add_single_message(
            Request.new("m"),
            %Message{role: "user", content: content},
            false
          )

        assert [%{"role" => "user", "content" => [^wire]}] = req.messages
      end
    end

    test "is counted by TokenEstimate" do
      block = %AudioBlock{id: "a1"}
      assert TokenEstimate.estimate_message_content_tokens(block) == 700
      assert TokenEstimate.estimate_message_content_tokens([block, Image.new_url("u")]) == 2300
    end

    test "is labelled by the Summarizer" do
      agent = BaseAgent.init(%{client: %RecordingClient{notify: self()}, model: "m"})
      messages = [%{role: "user", content: [Text.new("look"), %AudioBlock{id: "a1"}]}]

      assert {:ok, "summary"} =
               Summarizer.summarize_messages(%RecordingClient{notify: self()}, agent, messages)

      assert_received {:request, sent}
      assert inspect(sent) =~ "[audio]"
    end
  end

  test "a struct that is not a block has no implementation" do
    assert Protocol.impl_for(%NotABlock{}) == nil
  end
end
