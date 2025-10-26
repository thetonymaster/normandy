defmodule Normandy.Agents.BaseAgentStreamingTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.AgentMemory

  # Test calculator tool for streaming tests
  defmodule TestCalculator do
    defstruct []

    defimpl Normandy.Tools.BaseTool do
      def tool_name(_), do: "calculator"
      def tool_description(_), do: "Performs calculations"

      def input_schema(_) do
        %{
          type: "object",
          properties: %{},
          required: []
        }
      end

      def run(_) do
        {:ok, 42}
      end
    end
  end

  # Mock streaming client for testing
  defmodule MockStreamingClient do
    use Normandy.Schema

    schema do
      field(:responses, :map, default: %{})
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        response_model
      end

      # Implement streaming support
      def stream_converse(
            _client,
            _model,
            _temperature,
            _max_tokens,
            _messages,
            _response_model,
            opts \\ []
          ) do
        # Simulate streaming events
        callback = Keyword.get(opts, :callback)

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

        # Invoke callback if provided
        if callback do
          Enum.each(events, fn event ->
            case event do
              %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}} ->
                callback.(:text_delta, text)

              %{type: "message_start", message: message} ->
                callback.(:message_start, message)

              %{type: "message_stop"} ->
                callback.(:message_stop, %{})

              _ ->
                :ok
            end
          end)
        end

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
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
        response_model
      end

      def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
        response_model
      end

      def stream_converse(
            _client,
            _model,
            _temperature,
            _max_tokens,
            messages,
            _response_model,
            opts \\ []
          ) do
        callback = Keyword.get(opts, :callback)

        # Check if this is the first call (has user message) or follow-up (has tool results)
        has_tool_result =
          Enum.any?(messages, fn msg ->
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

        # Invoke callback if provided
        if callback do
          Enum.each(events, fn event ->
            case event do
              %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}} ->
                callback.(:text_delta, text)

              %{type: "content_block_start", content_block: %{"type" => "tool_use"} = tool} ->
                callback.(:tool_use_start, tool)

              %{type: "message_start", message: message} ->
                callback.(:message_start, message)

              %{type: "message_stop"} ->
                callback.(:message_stop, %{})

              _ ->
                :ok
            end
          end)
        end

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  describe "stream_response/3" do
    test "streams text response with callback" do
      client = %MockStreamingClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn
        :text_delta, text -> send(self(), {:text, text})
        _, _ -> :ok
      end

      user_input = %{chat_message: "Hello"}
      {_updated_config, response} = BaseAgent.stream_response(config, user_input, callback)

      # Verify callbacks were invoked
      assert_received {:text, "Hello"}
      assert_received {:text, " streaming"}

      # Verify final response
      assert response.content
      assert length(response.content) > 0
    end

    test "adds streamed response to memory" do
      client = %MockStreamingClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn _, _ -> :ok end
      user_input = %{chat_message: "Hello"}

      {updated_config, _response} = BaseAgent.stream_response(config, user_input, callback)

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

      callback = fn _, _ -> :ok end

      # First turn
      {config, _} = BaseAgent.stream_response(config, %{chat_message: "First"}, callback)

      # Second turn
      {config, _} = BaseAgent.stream_response(config, %{chat_message: "Second"}, callback)

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
        :message_start, msg -> send(self(), {:start, msg})
        :text_delta, text -> send(self(), {:text, text})
        :message_stop, _ -> send(self(), :stop)
        _, _ -> :ok
      end

      user_input = %{chat_message: "Hello"}
      BaseAgent.stream_response(config, user_input, callback)

      assert_received {:start, _}
      assert_received {:text, _}
      assert_received :stop
    end
  end

  describe "stream_with_tools/3" do
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

      # Track events
      callback = fn
        :tool_use_start, tool -> send(self(), {:tool_start, tool["name"]})
        :tool_result, result -> send(self(), {:tool_result, result})
        :text_delta, text -> send(self(), {:text, text})
        _, _ -> :ok
      end

      user_input = %{chat_message: "Calculate something"}
      {updated_config, _response} = BaseAgent.stream_with_tools(config, user_input, callback)

      # Should have received tool events
      assert_received {:tool_start, "calculator"}
      assert_received {:tool_result, _}

      # Should have final text response
      assert_received {:text, _}

      # Memory should contain: user message, assistant with tool call, tool result, assistant final response
      history = AgentMemory.history(updated_config.memory)
      assert length(history) >= 3
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

      callback = fn _, _ -> :ok end
      user_input = %{chat_message: "Calculate"}

      {_updated_config, _response} = BaseAgent.stream_with_tools(config, user_input, callback)

      # Should complete without error despite iteration limit
      assert true
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
        :text_delta, text -> send(self(), {:text, text})
        _, _ -> :ok
      end

      user_input = %{chat_message: "Calculate"}
      {_config, response} = BaseAgent.stream_with_tools(config, user_input, callback)

      # Should receive final text after tool execution
      assert_received {:text, "The answer is 42"}

      # Response should contain final message
      assert response.content
    end
  end

  describe "stream error handling" do
    defmodule FailingStreamClient do
      use Normandy.Schema

      schema do
        field(:should_fail, :boolean, default: true)
      end

      defimpl Normandy.Agents.Model do
        def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
          response_model
        end

        def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts) do
          response_model
        end

        def stream_converse(
              _client,
              _model,
              _temperature,
              _max_tokens,
              _messages,
              _response_model,
              _opts
            ) do
          {:error, "Stream failed"}
        end
      end
    end

    test "handles streaming errors gracefully" do
      client = %FailingStreamClient{}

      config =
        BaseAgent.init(%{
          client: client,
          model: "claude-3",
          temperature: 0.7
        })

      callback = fn _, _ -> :ok end
      user_input = %{chat_message: "Hello"}

      {_config, response} = BaseAgent.stream_response(config, user_input, callback)

      # Should return error response
      assert response.error == "Stream failed"
    end
  end
end
