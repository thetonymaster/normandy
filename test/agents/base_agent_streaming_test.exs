defmodule Normandy.Agents.BaseAgentStreamingTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.StreamEvent

  # Test calculator tool for streaming tests
  defmodule TestCalculator do
    use Normandy.Tool, name: "calculator", description: "Performs calculations"

    defstruct []

    @impl Normandy.Tool
    def input_schema(_tool), do: %{type: "object", properties: %{}, required: []}

    @impl Normandy.Tool
    def run(_tool, _context), do: {:ok, 42}
  end

  # Mock streaming client for testing
  defmodule MockStreamingClient do
    use Normandy.Schema

    schema do
      field(:responses, :map, default: %{})
    end

    defimpl Normandy.Agents.Model do
      def converse(_client, request, _opts),
        do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

      # Implement streaming support: the events only; Normandy calls the callback.
      def stream(_client, _request, _opts) do
        events = [
          %{
            type: "message_start",
            message: %{"id" => "msg_123", "model" => "claude-3", "role" => "assistant"}
          },
          %{
            type: "content_block_start",
            content_block: %{"type" => "text", "text" => ""},
            index: 0
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "text_delta", "text" => "Hello"},
            index: 0
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "text_delta", "text" => " streaming"},
            index: 0
          },
          %{
            type: "message_delta",
            delta: %{"stop_reason" => "end_turn"},
            usage: %{"output_tokens" => 3}
          },
          %{type: "message_stop"}
        ]

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  # Mock streaming client with tool calls
  defmodule MockStreamingClientWithTools do
    use Normandy.Schema

    schema do
      field(:tool_response, :string, default: "42")
    end

    defimpl Normandy.Agents.Model do
      def converse(_client, request, _opts),
        do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

      def stream(_client, request, _opts) do
        # Check if this is the first call (has user message) or follow-up (has tool results)
        has_tool_result =
          Enum.any?(request.messages, fn msg ->
            case msg do
              %{role: "tool"} -> true
              _ -> false
            end
          end)

        events =
          if has_tool_result do
            # Second call - return final text response
            [
              %{
                type: "message_start",
                message: %{"id" => "msg_456", "model" => "claude-3", "role" => "assistant"}
              },
              %{
                type: "content_block_start",
                content_block: %{"type" => "text", "text" => ""},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "text_delta", "text" => "The answer is 42"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          else
            # First call - return tool use
            [
              %{
                type: "message_start",
                message: %{"id" => "msg_123", "model" => "claude-3", "role" => "assistant"}
              },
              %{
                type: "content_block_start",
                content_block: %{"type" => "tool_use", "id" => "tool_1", "name" => "calculator"},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "input_json_delta", "partial_json" => "{}"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          end

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  describe "stream/3" do
    test "the returned response is the output schema, with no internal bookkeeping keys" do
      config = BaseAgent.init(%{client: %MockStreamingClient{}, model: "claude-3"})

      {:ok, _config, response} =
        BaseAgent.stream(config, %{chat_message: "Hi"}, fn _ -> :ok end)

      assert %BaseAgentOutputSchema{} = response
      refute Map.has_key?(response, :tool_calls)
      refute Map.has_key?(response, :prefix_key)
    end

    test "streams text response with callback" do
      client = %MockStreamingClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn
        %StreamEvent{type: :text_delta, data: text} -> send(self(), {:text, text})
        _ -> :ok
      end

      user_input = %{chat_message: "Hello"}
      {:ok, _updated_config, response} = BaseAgent.stream(config, user_input, callback)

      # Verify callbacks were invoked
      assert_received {:text, "Hello"}
      assert_received {:text, " streaming"}

      # Verify final response: the streamed text in the output schema
      assert response.chat_message == "Hello streaming"
    end

    test "adds streamed response to memory" do
      client = %MockStreamingClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn _ -> :ok end
      user_input = %{chat_message: "Hello"}

      {:ok, updated_config, _response} = BaseAgent.stream(config, user_input, callback)

      # Check memory contains both user and assistant messages
      history = AgentMemory.history(updated_config.memory)
      assert length(history) == 2

      # First should be user message
      user_msg = Enum.at(history, 0)
      assert user_msg.role == "user"

      # Second should be assistant message
      assistant_msg = Enum.at(history, 1)
      assert assistant_msg.role == "assistant"
    end

    test "continues conversation with existing memory" do
      client = %MockStreamingClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn _ -> :ok end

      # First turn
      {:ok, config, _} = BaseAgent.stream(config, %{chat_message: "First"}, callback)

      # Second turn
      {:ok, config, _} = BaseAgent.stream(config, %{chat_message: "Second"}, callback)

      # Should have 4 messages: 2 user, 2 assistant
      history = AgentMemory.history(config.memory)
      assert length(history) == 4
    end

    test "invokes callback for different event types" do
      client = %MockStreamingClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn
        %StreamEvent{type: :message_start, data: msg} -> send(self(), {:start, msg})
        %StreamEvent{type: :text_delta, data: text} -> send(self(), {:text, text})
        %StreamEvent{type: :message_stop} -> send(self(), :stop)
        _ -> :ok
      end

      user_input = %{chat_message: "Hello"}
      {:ok, _config, _response} = BaseAgent.stream(config, user_input, callback)

      assert_received {:start, _}
      assert_received {:text, _}
      assert_received :stop
    end
  end

  describe "stream/3 with tools" do
    test "executes tool calls during streaming" do
      client = %MockStreamingClientWithTools{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      # Register calculator tool
      tool = %TestCalculator{}
      config = BaseAgent.register_tool(config, tool)

      # Capture parent PID outside the callback. With max_tool_concurrency >= 1,
      # tool_result callbacks run in Task.async_stream worker processes — using
      # `self()` inside the callback would target the worker, not the test.
      parent = self()

      # Track events
      callback = fn
        %StreamEvent{type: :tool_use_start, data: tool} -> send(parent, {:tool_start, tool.name})
        %StreamEvent{type: :tool_result, data: result} -> send(parent, {:tool_result, result})
        %StreamEvent{type: :text_delta, data: text} -> send(parent, {:text, text})
        _ -> :ok
      end

      user_input = %{chat_message: "Calculate something"}
      {:ok, updated_config, _response} = BaseAgent.stream(config, user_input, callback)

      # Should have received tool events
      assert_received {:tool_start, "calculator"}
      assert_received {:tool_result, _}

      # Should have final text response
      assert_received {:text, _}

      # Memory should contain: user message, assistant with tool call, tool result, assistant final response
      history = AgentMemory.history(updated_config.memory)
      assert length(history) >= 3
    end

    # Regression: `execute_streaming_tool_loop/3` used to store the raw
    # StreamProcessor map as the assistant message. `AgentMemory.history/1`
    # then routed it through `BaseIOSchema.Map.to_json`, which
    # encodes the whole thing into a JSON string — destroying
    # the tool_use block structure. On the next iteration, Anthropic
    # received the assistant turn as plain text and rejected the trailing
    # tool_result block with `unexpected tool_use_id`. The fix wraps the
    # response in a `%ToolCallResponse{}` whose BaseIOSchema impl emits a
    # list of content blocks that survives round-tripping.
    test "preserves assistant tool_use content as a list across memory round-trip" do
      client = %MockStreamingClientWithTools{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      tool = %TestCalculator{}
      config = BaseAgent.register_tool(config, tool)

      callback = fn _ -> :ok end

      {:ok, updated_config, _response} =
        BaseAgent.stream(config, %{chat_message: "Calculate"}, callback)

      history = AgentMemory.history(updated_config.memory)

      # Find the assistant turn that carried the tool_use. In the broken
      # code, .content was a JSON string and this Enum.find/2 returned nil.
      assistant_tool_msg =
        Enum.find(history, fn msg ->
          msg.role == "assistant" and is_list(msg.content) and
            Enum.any?(msg.content, fn block ->
              block_type(block) == "tool_use"
            end)
        end)

      assert assistant_tool_msg,
             "assistant message with tool_use must have list content (got: " <>
               inspect(Enum.find(history, &(&1.role == "assistant"))) <> ")"

      tool_use_block =
        Enum.find(assistant_tool_msg.content, fn b -> block_type(b) == "tool_use" end)

      assert block_field(tool_use_block, "name") == "calculator"
      assert block_field(tool_use_block, "id") != nil
    end

    test "handles max iterations limit" do
      client = %MockStreamingClientWithTools{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7,
          # Only allow 1 iteration
          max_tool_iterations: 1
        })

      tool = %TestCalculator{}
      config = BaseAgent.register_tool(config, tool)

      callback = fn _ -> :ok end
      user_input = %{chat_message: "Calculate"}

      # Should complete without error despite iteration limit
      assert {:ok, _updated_config, _response} = BaseAgent.stream(config, user_input, callback)
    end

    test "max iterations forced-final returns a clean response and persists a tool turn" do
      client = %MockStreamingClientWithTools{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7,
          # Only allow 1 iteration: stream a tool call, dispatch it, hit the
          # cap, then force one final streaming call (the awaiting_final path).
          max_tool_iterations: 1
        })

      tool = %TestCalculator{}
      config = BaseAgent.register_tool(config, tool)

      callback = fn _ -> :ok end
      user_input = %{chat_message: "Calculate"}

      {:ok, updated_config, response} = BaseAgent.stream(config, user_input, callback)

      # The forced-final streaming call produced a final answer, converted to the
      # output schema by the core's convert step, as on the normal path.
      assert %BaseAgentOutputSchema{chat_message: text} = response
      assert is_binary(text)

      # The synthetic :tool_calls key must be stripped from the returned response.
      refute Map.has_key?(response, :tool_calls)

      # The dispatched tool result was recorded before the forced-final call.
      roles = AgentMemory.history(updated_config.memory) |> Enum.map(& &1.role)
      assert "tool" in roles
    end

    test "streams final response after tool execution" do
      client = %MockStreamingClientWithTools{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      tool = %TestCalculator{}
      config = BaseAgent.register_tool(config, tool)

      callback = fn
        %StreamEvent{type: :text_delta, data: text} -> send(self(), {:text, text})
        _ -> :ok
      end

      user_input = %{chat_message: "Calculate"}
      {:ok, _config, response} = BaseAgent.stream(config, user_input, callback)

      # Should receive final text after tool execution
      assert_received {:text, "The answer is 42"}

      # Response should contain final message
      assert response.chat_message == "The answer is 42"
    end
  end

  describe "stream error handling" do
    defmodule FailingStreamClient do
      use Normandy.Schema

      schema do
        field(:should_fail, :boolean, default: true)
      end

      defimpl Normandy.Agents.Model do
        def converse(_client, request, _opts),
          do: {:ok, %Normandy.LLM.Response{content: request.response_model}}

        def stream(_client, _request, _opts),
          do:
            {:error,
             Normandy.LLMError.new(type: :unknown, retryable?: false, reason: "Stream failed")}
      end
    end

    test "a failed stream/3 returns LLMError" do
      client = %FailingStreamClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn _ -> :ok end
      user_input = %{chat_message: "Hello"}

      assert {:error, %Normandy.LLMError{type: :unknown, reason: "Stream failed"}} =
               BaseAgent.stream(config, user_input, callback)
    end
  end

  # Content blocks come back from BaseIOSchema.to_json with mixed key
  # conventions (string or atom) depending on the source — these helpers
  # normalize reads so assertions don't need to guess.
  defp block_type(block), do: block_field(block, "type")

  defp block_field(block, key) when is_map(block) do
    Map.get(block, key) || Map.get(block, String.to_atom(key))
  end

  defp block_field(_block, _key), do: nil
end
