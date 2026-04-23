defmodule NormandyTest.LLM.ClaudioAdapterMultimodalTest do
  @moduledoc """
  Exercises `Normandy.LLM.ClaudioAdapter`'s multimodal dispatch in
  `add_single_message/3` without making any HTTP calls.

  The adapter's protocol implementation exposes `add_single_message/3`
  for this purpose — the test calls it directly via its qualified name
  and inspects the resulting `Claudio.Messages.Request.messages` list.
  """

  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Components.ContentBlock.Document, as: DocumentBlock
  alias Normandy.Components.ContentBlock.Image, as: ImageBlock
  alias Normandy.Components.ContentBlock.Text, as: TextBlock
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter

  defmodule OpaqueStruct do
    defstruct [:payload]
  end

  # Inside a `defimpl`, a public `def` is accessible at this qualified name.
  @impl_module Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter

  defp new_request, do: Request.new("test-model")

  defp add(message, enable_caching \\ false) do
    @impl_module.add_single_message(new_request(), message, enable_caching)
  end

  defp single_message(%Request{messages: [msg]}), do: msg

  describe "string content (backward-compat)" do
    test "passes plain user text through add_message/3 unchanged" do
      msg = %Message{role: "user", content: "hello"}
      req = add(msg)

      assert single_message(req) == %{"role" => "user", "content" => "hello"}
    end

    test "passes plain assistant text through add_message/3 unchanged" do
      msg = %Message{role: "assistant", content: "hi back"}
      req = add(msg)

      assert single_message(req) == %{"role" => "assistant", "content" => "hi back"}
    end

    test "system string content routes to set_system (no messages appended)" do
      msg = %Message{role: "system", content: "You are helpful."}
      req = add(msg)

      assert req.system == "You are helpful."
      assert req.messages == []
    end

    test "system string content routes to set_system_with_cache when caching enabled" do
      msg = %Message{role: "system", content: "Cache me."}
      req = add(msg, true)

      # set_system_with_cache wraps the text in a list with cache_control
      assert is_list(req.system)
      assert [%{"type" => "text", "text" => "Cache me.", "cache_control" => _}] = req.system
    end
  end

  describe "multimodal dispatch — wrapped shapes use Claudio helpers" do
    test "[Image base64, Text] emits the base64 image + text content list" do
      msg = %Message{
        role: "user",
        content: [
          ImageBlock.new_base64("BASE64DATA", "image/png"),
          TextBlock.new("What's in this image?")
        ]
      }

      req = add(msg)

      assert single_message(req) == %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "base64",
                     "media_type" => "image/png",
                     "data" => "BASE64DATA"
                   }
                 },
                 %{"type" => "text", "text" => "What's in this image?"}
               ]
             }
    end

    test "[Image url, Text] emits the url image + text content list" do
      msg = %Message{
        role: "user",
        content: [
          ImageBlock.new_url("https://example.com/cat.png"),
          TextBlock.new("Describe it.")
        ]
      }

      req = add(msg)

      assert single_message(req) == %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{
                     "type" => "url",
                     "url" => "https://example.com/cat.png"
                   }
                 },
                 %{"type" => "text", "text" => "Describe it."}
               ]
             }
    end

    test "[Document, Text] emits the file_id document + text content list" do
      msg = %Message{
        role: "user",
        content: [
          DocumentBlock.new_file("file_abc123"),
          TextBlock.new("Summarize it.")
        ]
      }

      req = add(msg)

      assert single_message(req) == %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "document",
                   "source" => %{"type" => "file", "file_id" => "file_abc123"}
                 },
                 %{"type" => "text", "text" => "Summarize it."}
               ]
             }
    end
  end

  describe "multimodal dispatch — other shapes fall through to raw-list" do
    test "[Text, Image] reversed order emits the list in caller-provided order" do
      msg = %Message{
        role: "user",
        content: [
          TextBlock.new("Look at this:"),
          ImageBlock.new_url("https://example.com/pic.jpg")
        ]
      }

      req = add(msg)

      assert %{"role" => "user", "content" => blocks} = single_message(req)

      assert blocks == [
               %{"type" => "text", "text" => "Look at this:"},
               %{
                 "type" => "image",
                 "source" => %{"type" => "url", "url" => "https://example.com/pic.jpg"}
               }
             ]
    end

    test "multi-block [Text, Image, Text] preserves order and shape" do
      msg = %Message{
        role: "user",
        content: [
          TextBlock.new("Before:"),
          ImageBlock.new_base64("D", "image/jpeg"),
          TextBlock.new("After.")
        ]
      }

      req = add(msg)

      assert %{"content" => [first, image, last]} = single_message(req)
      assert first == %{"type" => "text", "text" => "Before:"}
      assert %{"type" => "image", "source" => %{"type" => "base64"}} = image
      assert last == %{"type" => "text", "text" => "After."}
    end

    test "single-block [Image] (no text) falls through to raw-list" do
      msg = %Message{
        role: "user",
        content: [ImageBlock.new_base64("X", "image/png")]
      }

      req = add(msg)

      assert %{"role" => "user", "content" => [%{"type" => "image"}]} = single_message(req)
    end

    test "pre-shaped caller maps pass through untouched (future-proofing)" do
      # A caller building a cache_control-annotated block by hand should
      # not be re-wrapped or validated.
      raw = %{
        "type" => "image",
        "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "D"},
        "cache_control" => %{"type" => "ephemeral"}
      }

      msg = %Message{role: "user", content: [raw, TextBlock.new("annotate")]}
      req = add(msg)

      assert %{"content" => [^raw, %{"type" => "text", "text" => "annotate"}]} =
               single_message(req)
    end

    test "assistant role multimodal goes through same dispatch" do
      msg = %Message{
        role: "assistant",
        content: [
          ImageBlock.new_url("https://x/i.png"),
          TextBlock.new("Here.")
        ]
      }

      req = add(msg)

      assert %{"role" => "assistant", "content" => [%{"type" => "image"}, %{"type" => "text"}]} =
               single_message(req)
    end
  end

  describe "regression: struct content (existing pass-through)" do
    test "non-list struct content goes through opaquely" do
      # Matches the existing pre-multimodal path where callers pass a
      # serialized I/O schema as a struct.
      struct_msg = %OpaqueStruct{payload: "blob"}

      msg = %Message{role: "user", content: struct_msg}
      req = add(msg)

      # Claudio's normalize_content passes structs through as-is in the
      # `_ -> content` catch-all clause. We only assert the adapter
      # doesn't crash and the message shape carries the struct forward.
      assert %{"role" => "user", "content" => ^struct_msg} = single_message(req)
    end
  end

  describe "full adapter schema is untouched" do
    test "ClaudioAdapter struct still builds with existing fields" do
      adapter = %ClaudioAdapter{api_key: "k", options: %{timeout: 1_000}}
      assert adapter.api_key == "k"
    end
  end
end
