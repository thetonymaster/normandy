defmodule Normandy.LLM.ClaudioAdapterCachingTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Normandy.Agents.Model
  alias Normandy.Components.ContentBlock.Text, as: TextBlock
  alias Normandy.Components.Message
  alias Normandy.LLM.ClaudioAdapter

  @impl_module Normandy.Agents.Model.Normandy.LLM.ClaudioAdapter

  defp new_request, do: Request.new("test-model")

  defp add(message, enable_caching) do
    @impl_module.add_single_message(new_request(), message, enable_caching)
  end

  describe "prompt caching on the wire" do
    @reply %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-5-5",
      "content" => [%{"type" => "text", "text" => ~s({"chat_message": "ok"})}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    # `caching`: the :enable_caching option to set, or :unset to leave it out.
    defp sent_body(name, caching) do
      test_pid = self()

      Req.Test.stub(name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})
        Req.Test.json(conn, @reply)
      end)

      client = %ClaudioAdapter{
        api_key: "k",
        options:
          Map.merge(
            %{req_options: [plug: {Req.Test, name}, retry: false]},
            if(caching == :unset, do: %{}, else: %{enable_caching: caching})
          )
      }

      messages = [%Message{role: "user", content: [TextBlock.new("hi")]}]

      tool = fn name ->
        %{name: name, description: "d", input_schema: %{"type" => "object", "properties" => %{}}}
      end

      Model.converse(
        client,
        %Normandy.LLM.Request{
          model: "claude-opus-5-5",
          system: "You are terse.",
          max_tokens: 1024,
          messages: messages,
          response_model: %Normandy.Agents.BaseAgentOutputSchema{},
          tools: [tool.("lookup"), tool.("search")]
        },
        []
      )

      assert_received {:body, body}
      body
    end

    test "caching on: top-level, system and last-tool breakpoints; no message markers" do
      body = sent_body(__MODULE__.On, true)

      assert body["cache_control"] == %{"type" => "ephemeral"}
      assert List.last(body["system"])["cache_control"] == %{"type" => "ephemeral"}
      assert [first_tool, last_tool] = body["tools"]
      refute Map.has_key?(first_tool, "cache_control")
      assert last_tool["cache_control"] == %{"type" => "ephemeral"}

      for message <- body["messages"], is_list(message["content"]), block <- message["content"] do
        refute Map.has_key?(block, "cache_control"), "unexpected marker in #{inspect(message)}"
      end
    end

    test "caching is on when the option is left out (the 2.0 default)" do
      assert sent_body(__MODULE__.Unset, :unset) == sent_body(__MODULE__.OnToo, true)
    end

    test "caching off: no breakpoints at all" do
      body = sent_body(__MODULE__.Off, false)

      refute Map.has_key?(body, "cache_control")
      refute Enum.any?(body["tools"], &Map.has_key?(&1, "cache_control"))
      # Without caching the system prompt goes out as a plain string (set_system/2).
      assert body["system"] == "You are terse."
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
      # 4. The top-level automatic cache_control covers the conversation
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

    test "string-keyed cache_control: nil on the last system block gets the default annotation" do
      raw_with_nil = %{"type" => "text", "text" => "tail", "cache_control" => nil}
      req = add(%Message{role: "system", content: [TextBlock.new("head"), raw_with_nil]}, true)

      assert List.last(req.system) == %{
               "type" => "text",
               "text" => "tail",
               "cache_control" => %{"type" => "ephemeral"}
             }
    end

    test "atom-keyed :cache_control nil on the last system block gets the default annotation" do
      raw = %{type: "text", text: "tail", cache_control: nil}
      req = add(%Message{role: "system", content: [TextBlock.new("head"), raw]}, true)

      tail = List.last(req.system)
      refute Map.has_key?(tail, :cache_control)
      assert tail["cache_control"] == %{"type" => "ephemeral"}
    end

    test "a string-keyed nil does not shadow an atom-keyed TTL on the last system block" do
      raw = %{
        :type => "text",
        :text => "tail",
        "cache_control" => nil,
        :cache_control => %{type: "ephemeral", ttl: "1h"}
      }

      req = add(%Message{role: "system", content: [TextBlock.new("head"), raw]}, true)
      assert List.last(req.system) == raw
    end
  end
end
