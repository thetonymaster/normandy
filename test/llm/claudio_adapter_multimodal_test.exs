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

  defp add_all(messages, enable_caching) do
    @impl_module.add_messages(new_request(), messages, enable_caching)
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

  describe "single ContentBlock struct as content (sugar for one-element list)" do
    test "single TextBlock emits same wire shape as [TextBlock]" do
      req_single = add(%Message{role: "user", content: TextBlock.new("hi")})
      req_list = add(%Message{role: "user", content: [TextBlock.new("hi")]})

      assert single_message(req_single) == single_message(req_list)
    end

    test "single ImageBlock emits image content list (no struct in wire shape)" do
      req = add(%Message{role: "user", content: ImageBlock.new_base64("D", "image/png")})

      assert %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image",
                   "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "D"}
                 }
               ]
             } = single_message(req)
    end

    test "single DocumentBlock emits document content list" do
      req = add(%Message{role: "user", content: DocumentBlock.new_file("file_x")})

      assert %{
               "role" => "user",
               "content" => [
                 %{"type" => "document", "source" => %{"type" => "file", "file_id" => "file_x"}}
               ]
             } = single_message(req)
    end

    test "non-ContentBlock single struct still passes through opaquely (backward-compat)" do
      # OpaqueStruct is not a ContentBlock — existing I/O schema pattern
      # where callers assign a serialized struct as content.
      struct_msg = %OpaqueStruct{payload: "blob"}
      req = add(%Message{role: "user", content: struct_msg})

      assert %{"role" => "user", "content" => ^struct_msg} = single_message(req)
    end
  end

  describe "named-helper guards: empty fields fall through and raise via to_claudio/1" do
    # Constructors (`new_base64/2`, `new_url/1`, `new_file/1`) enforce
    # non-empty fields, but a caller bypassing them with raw struct
    # literals must still hit the ArgumentError that
    # `ContentBlock.{Image,Document}.to_claudio/1` raises — not silently
    # take the named-helper path with empty data.

    test "ImageBlock base64 with empty data falls through and raises" do
      msg = %Message{
        role: "user",
        content: [
          %ImageBlock{source: :base64, data: "", media_type: "image/png"},
          TextBlock.new("describe")
        ]
      }

      assert_raise ArgumentError, ~r/invalid base64 image/, fn -> add(msg) end
    end

    test "ImageBlock base64 with empty media_type falls through and raises" do
      msg = %Message{
        role: "user",
        content: [
          %ImageBlock{source: :base64, data: "D", media_type: ""},
          TextBlock.new("describe")
        ]
      }

      assert_raise ArgumentError, ~r/invalid base64 image/, fn -> add(msg) end
    end

    test "ImageBlock url with empty url falls through and raises" do
      msg = %Message{
        role: "user",
        content: [%ImageBlock{source: :url, url: ""}, TextBlock.new("describe")]
      }

      assert_raise ArgumentError, ~r/invalid url image/, fn -> add(msg) end
    end

    test "DocumentBlock with empty file_id falls through and raises" do
      msg = %Message{
        role: "user",
        content: [%DocumentBlock{source: :file_id, file_id: ""}, TextBlock.new("summarize")]
      }

      assert_raise ArgumentError, ~r/invalid document/, fn -> add(msg) end
    end
  end

  describe "defensive guards for unsafe shapes" do
    test "system role with list content converts blocks to raw-shape list" do
      msg = %Message{role: "system", content: [TextBlock.new("sys")]}
      req = add(msg)

      assert req.system == [%{"type" => "text", "text" => "sys"}]
      assert req.messages == []
    end

    test "system role with list content + caching enabled annotates the last block" do
      # Multimodal/list-form system caching: the adapter sets
      # `cache_control: {"type": "ephemeral"}` on the last block before
      # passing the list to Claudio's `set_system/2` (since
      # `set_system_with_cache/2` only wraps strings).
      msg = %Message{role: "system", content: [TextBlock.new("sys")]}
      req = add(msg, true)

      assert req.system == [
               %{"type" => "text", "text" => "sys", "cache_control" => %{"type" => "ephemeral"}}
             ]
    end

    test "tool role with list of ContentBlock structs routes via block_to_claudio" do
      msg = %Message{role: "tool", content: [TextBlock.new("tool result")]}
      req = add(msg)

      assert single_message(req) == %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "tool result"}]
             }
    end

    test "tool role with a pre-shaped map list is still preserved (backward-compat)" do
      # BaseIOSchema-derived tool_result shape — already Anthropic-shape.
      pre_shaped = [
        %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "ok", "is_error" => false}
      ]

      msg = %Message{role: "tool", content: pre_shaped}
      req = add(msg)

      assert single_message(req) == %{"role" => "user", "content" => pre_shaped}
    end

    test "unknown struct in content list raises ArgumentError" do
      msg = %Message{
        role: "user",
        content: [%OpaqueStruct{payload: "x"}, TextBlock.new("t")]
      }

      assert_raise ArgumentError, ~r/unsupported content block/, fn -> add(msg) end
    end

    test "empty content list raises ArgumentError (user role)" do
      msg = %Message{role: "user", content: []}
      assert_raise ArgumentError, ~r/content list must be non-empty/, fn -> add(msg) end
    end

    test "empty content list raises ArgumentError (assistant role)" do
      msg = %Message{role: "assistant", content: []}
      assert_raise ArgumentError, ~r/content list must be non-empty/, fn -> add(msg) end
    end

    test "empty content list raises ArgumentError (system role)" do
      msg = %Message{role: "system", content: []}
      assert_raise ArgumentError, ~r/content list must be non-empty/, fn -> add(msg) end
    end

    test "empty content list raises ArgumentError (tool role)" do
      msg = %Message{role: "tool", content: []}
      assert_raise ArgumentError, ~r/content list must be non-empty/, fn -> add(msg) end
    end

    test "a system message after the first message raises ArgumentError" do
      # set_system/2 replaces, so a later system message would silently
      # overwrite the agent's system prompt.
      messages = [
        %Message{role: "system", content: "real prompt"},
        %Message{role: "user", content: "hi"},
        %Message{role: "system", content: "summary", turn_id: "t-7"}
      ]

      assert_raise ArgumentError, ~r/system message at position 2.*"t-7"/, fn ->
        add_all(messages, false)
      end
    end

    test "a second leading system message raises ArgumentError" do
      messages = [
        %Message{role: "system", content: "real prompt"},
        %Message{role: "system", content: "another"}
      ]

      assert_raise ArgumentError, ~r/system message at position 1/, fn ->
        add_all(messages, false)
      end
    end

    test "unrecognized role raises ArgumentError naming the role" do
      # e.g. caller typo, or OpenAI's "function" role passed in by mistake
      msg = %Message{role: "function", content: "x", turn_id: "t-42"}

      assert_raise ArgumentError, ~r/unrecognized message role.*"function"/, fn -> add(msg) end
    end

    test "unrecognized role error includes turn_id for traceability" do
      msg = %Message{role: "System", content: "typo", turn_id: "t-99"}

      assert_raise ArgumentError, ~r/t-99/, fn -> add(msg) end
    end
  end

  # Tests in this block assert the adapter's *passthrough contract*: whatever
  # content-block shape the caller hands in, the adapter ships it verbatim
  # (modulo ContentBlock-struct → wire-map conversion). The inline hand-built
  # maps in tests 2–5 are illustrative of common Anthropic product shapes but
  # are not normative — if Anthropic's shapes drift, callers will update their
  # own hand-built maps and the passthrough still holds.
  describe "product scenarios — shapes Claudio helpers don't wrap" do
    test "mood-board: 5 base64 images + 1 text prompt falls through to raw-list" do
      # Six blocks in one message: each becomes its API map, in order.
      images =
        for n <- 1..5 do
          ImageBlock.new_base64("IMG#{n}DATA", "image/jpeg")
        end

      msg = %Message{
        role: "user",
        content: images ++ [TextBlock.new("Pick a palette from these inspirations.")]
      }

      req = add(msg)

      assert %{"role" => "user", "content" => blocks} = single_message(req)
      assert length(blocks) == 6

      image_blocks = Enum.take(blocks, 5)
      text_block = List.last(blocks)

      for {block, n} <- Enum.with_index(image_blocks, 1) do
        assert block == %{
                 "type" => "image",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "image/jpeg",
                   "data" => "IMG#{n}DATA"
                 }
               }
      end

      assert text_block == %{
               "type" => "text",
               "text" => "Pick a palette from these inspirations."
             }
    end

    test "base64 PDF + prompt: hand-built document map passes through verbatim" do
      # Document struct doesn't model base64 source — caller hand-builds.
      pdf_block = %{
        "type" => "document",
        "source" => %{
          "type" => "base64",
          "media_type" => "application/pdf",
          "data" => "JVBERi0xLjQK"
        }
      }

      msg = %Message{
        role: "user",
        content: [pdf_block, TextBlock.new("Summarize this vendor contract.")]
      }

      req = add(msg)

      assert single_message(req) == %{
               "role" => "user",
               "content" => [
                 pdf_block,
                 %{"type" => "text", "text" => "Summarize this vendor contract."}
               ]
             }
    end

    test "URL-sourced PDF + prompt: hand-built document map passes through verbatim" do
      # Document struct doesn't model URL source — caller hand-builds.
      pdf_block = %{
        "type" => "document",
        "source" => %{
          "type" => "url",
          "url" => "https://vendor.example/catalog.pdf"
        }
      }

      msg = %Message{
        role: "user",
        content: [pdf_block, TextBlock.new("What packages do they offer?")]
      }

      req = add(msg)

      assert single_message(req) == %{
               "role" => "user",
               "content" => [
                 pdf_block,
                 %{"type" => "text", "text" => "What packages do they offer?"}
               ]
             }
    end

    test "Files-API image source + prompt: hand-built image map passes through verbatim" do
      # Image struct models :base64 and :url only — caller hand-builds Files-API.
      image_block = %{
        "type" => "image",
        "source" => %{
          "type" => "file",
          "file_id" => "file_xyz123"
        }
      }

      msg = %Message{
        role: "user",
        content: [image_block, TextBlock.new("Does this match the new mood board?")]
      }

      req = add(msg)

      assert single_message(req) == %{
               "role" => "user",
               "content" => [
                 image_block,
                 %{"type" => "text", "text" => "Does this match the new mood board?"}
               ]
             }
    end

    test "cache_control on image: hand-built image map preserves the annotation" do
      # ImageBlock struct doesn't carry cache_control — caller annotates a map.
      cached_image = %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => "image/png",
          "data" => "INSPIRATION_DATA"
        },
        "cache_control" => %{"type" => "ephemeral"}
      }

      msg = %Message{
        role: "user",
        content: [cached_image, TextBlock.new("Critique this inspiration photo.")]
      }

      req = add(msg)

      assert %{"role" => "user", "content" => [image, _text]} = single_message(req)
      assert image == cached_image
    end
  end

  describe "full adapter schema is untouched" do
    test "ClaudioAdapter struct still builds with existing fields" do
      adapter = %ClaudioAdapter{api_key: "k", options: %{timeout: 1_000}}
      assert adapter.api_key == "k"
    end
  end

  # Conversation caching is Claudio's top-level automatic breakpoint (D19): the API
  # places it on the last cacheable block of any role, tool results included.
  # Normandy adds no marker to message blocks; markers a caller set pass through.
  describe "conversation caching: top-level automatic breakpoint" do
    test "caching on sets top-level cache_control and leaves message blocks unmarked" do
      messages = [
        %Message{role: "user", content: [TextBlock.new("first turn")]},
        %Message{role: "assistant", content: "ack"},
        %Message{
          role: "user",
          content: [ImageBlock.new_url("https://e/i.png"), TextBlock.new("describe")]
        }
      ]

      req = add_all(messages, true)

      assert req.cache_control == %{"type" => "ephemeral"}
      assert [first_user, _assistant, last_user] = req.messages

      assert first_user == %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "first turn"}]
             }

      assert last_user == %{
               "role" => "user",
               "content" => [
                 %{"type" => "image", "source" => %{"type" => "url", "url" => "https://e/i.png"}},
                 %{"type" => "text", "text" => "describe"}
               ]
             }
    end

    test "a trailing tool-result message gets no Normandy marker either" do
      messages = [
        %Message{role: "user", content: [TextBlock.new("go")]},
        %Message{
          role: "tool",
          content: [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "42"}]
        }
      ]

      req = add_all(messages, true)

      assert req.cache_control == %{"type" => "ephemeral"}
      assert %{"role" => "user", "content" => [tool_result]} = List.last(req.messages)
      refute Map.has_key?(tool_result, "cache_control")
    end

    test "single ContentBlock struct content is wrapped, not marked" do
      req = add_all([%Message{role: "user", content: TextBlock.new("just text")}], true)

      assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => "just text"}]}] =
               req.messages

      assert req.cache_control == %{"type" => "ephemeral"}
    end

    test "a caller's own marker is preserved verbatim" do
      messages = [
        %Message{
          role: "user",
          content: [
            ImageBlock.new_url("https://e/i.png"),
            TextBlock.new("desc") |> TextBlock.with_cache(%{"type" => "ephemeral", "ttl" => "1h"})
          ]
        }
      ]

      req = add_all(messages, true)

      assert [%{"content" => [_image, text]}] = req.messages

      assert text == %{
               "type" => "text",
               "text" => "desc",
               "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
             }
    end

    test "plain-string user content is unchanged" do
      req = add_all([%Message{role: "user", content: "hello"}], true)
      assert req.messages == [%{"role" => "user", "content" => "hello"}]
    end

    test "opaque (non-ContentBlock) struct content is unchanged" do
      struct_msg = %OpaqueStruct{payload: "blob"}
      req = add_all([%Message{role: "user", content: struct_msg}], true)
      assert [%{"role" => "user", "content" => ^struct_msg}] = req.messages
    end

    test "caching off: no top-level cache_control, messages unchanged" do
      req = add_all([%Message{role: "user", content: [TextBlock.new("hi")]}], false)

      assert req.cache_control == nil

      assert req.messages == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}
             ]
    end

    test "no user message: no error, top-level cache_control still set" do
      req = add_all([%Message{role: "system", content: "sys"}], true)
      assert req.messages == []
      assert req.cache_control == %{"type" => "ephemeral"}
    end

    test "atom-keyed :cache_control on a raw caller map ships verbatim" do
      atom_keyed = %{
        type: "image",
        source: %{type: "base64", media_type: "image/png", data: "D"},
        cache_control: %{type: "ephemeral", ttl: "1h"}
      }

      req = add_all([%Message{role: "user", content: [atom_keyed]}], true)

      assert [%{"content" => [block]}] = req.messages
      assert block == atom_keyed
      refute Map.has_key?(block, "cache_control")
    end

    test "blocks built via with_cache/1 ship cache_control with caching off" do
      messages = [
        %Message{
          role: "user",
          content: [
            ImageBlock.new_base64("D", "image/png") |> ImageBlock.with_cache(),
            TextBlock.new("plain")
          ]
        }
      ]

      req = add_all(messages, false)

      assert [%{"content" => [image, text]}] = req.messages
      assert image["cache_control"] == %{"type" => "ephemeral"}
      assert text == %{"type" => "text", "text" => "plain"}
    end
  end
end
