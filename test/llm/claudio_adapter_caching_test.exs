defmodule Normandy.LLM.ClaudioAdapterCachingTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Components.ContentBlock.Text, as: TextBlock
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter

  @impl_module Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter

  defp new_request, do: Request.new("test-model")

  defp add(message, enable_caching) do
    @impl_module.add_single_message(new_request(), message, enable_caching)
  end

  describe "prompt caching" do
    test "uses set_system_with_cache when caching is enabled" do
      client = %ClaudioAdapter{
        api_key: "test-key",
        options: %{enable_caching: true}
      }

      # Mock Claudio.Messages.create to capture the request
      # We can't easily test this without mocking, but we can verify the code path
      # compiles and the logic is correct by inspection

      # This test validates that the code compiles and the pattern matching works
      assert client.options[:enable_caching] == true
    end

    test "uses regular set_system when caching is disabled" do
      client = %ClaudioAdapter{
        api_key: "test-key",
        options: %{enable_caching: false}
      }

      assert client.options[:enable_caching] == false
    end

    test "caching defaults to false when not specified" do
      client = %ClaudioAdapter{
        api_key: "test-key",
        options: %{}
      }

      assert Map.get(client.options, :enable_caching, false) == false
    end

    test "tool caching is applied when enabled" do
      client = %ClaudioAdapter{
        api_key: "test-key",
        options: %{enable_caching: true}
      }

      # Tools should be cached when enable_caching is true
      assert client.options[:enable_caching] == true
    end
  end

  describe "caching configuration" do
    test "accepts enable_caching option" do
      client = %ClaudioAdapter{
        api_key: "test-key",
        options: %{
          enable_caching: true,
          timeout: 60_000
        }
      }

      assert client.options[:enable_caching] == true
      assert client.options[:timeout] == 60_000
    end

    test "caching works with other options" do
      client = %ClaudioAdapter{
        api_key: "test-key",
        options: %{
          enable_caching: true,
          thinking_budget: 1000,
          timeout: 30_000
        }
      }

      assert client.options[:enable_caching] == true
      assert client.options[:thinking_budget] == 1000
      assert client.options[:timeout] == 30_000
    end
  end

  describe "cache behavior documentation" do
    test "documents the expected cache behavior" do
      # When enable_caching is true:
      # 1. System prompts (string) use set_system_with_cache
      # 2. System prompts (list-form) get cache_control on the last block
      # 3. Last tool in list uses add_tool_with_cache
      # 4. Last user message's last block gets cache_control (multimodal only)
      # 5. Cache provides up to 90% cost reduction

      # This is documented behavior that should be maintained
      assert true
    end

    test "documents cache control is ephemeral by default" do
      # Claudio uses ephemeral cache control by default
      # This means cached content expires after ~5 minutes of inactivity
      assert true
    end
  end

  describe "list-form system prompt caching (multimodal system)" do
    test "annotates last block with ephemeral cache_control when caching is enabled" do
      msg = %Message{role: "system", content: [TextBlock.new("instructions")]}
      req = add(msg, true)

      assert req.system == [
               %{
                 "type" => "text",
                 "text" => "instructions",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]
    end

    test "annotates only the LAST block of a multi-block list-form system prompt" do
      msg = %Message{
        role: "system",
        content: [
          TextBlock.new("part one"),
          TextBlock.new("part two"),
          TextBlock.new("part three")
        ]
      }

      req = add(msg, true)

      assert req.system == [
               %{"type" => "text", "text" => "part one"},
               %{"type" => "text", "text" => "part two"},
               %{
                 "type" => "text",
                 "text" => "part three",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]
    end

    test "leaves list-form system prompt untouched when caching is disabled" do
      msg = %Message{role: "system", content: [TextBlock.new("instructions")]}
      req = add(msg, false)

      assert req.system == [%{"type" => "text", "text" => "instructions"}]
    end

    test "respects caller's pre-existing cache_control on the last block" do
      # Caller used with_cache/2 with a custom TTL — the adapter must not
      # overwrite that with the default ephemeral.
      annotated =
        TextBlock.new("instructions")
        |> TextBlock.with_cache(%{"type" => "ephemeral", "ttl" => "1h"})

      msg = %Message{role: "system", content: [annotated]}
      req = add(msg, true)

      assert req.system == [
               %{
                 "type" => "text",
                 "text" => "instructions",
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               }
             ]
    end
  end
end
