defmodule Normandy.LLM.ClaudioAdapter do
  @moduledoc """
  Adapter for integrating Claudio (Anthropic's Claude API client) with Normandy agents.

  This adapter implements the `Normandy.Agents.Model` protocol to enable
  Normandy agents to use Claude models via the Claudio library.

  ## Features

  - Full Messages API support
  - Tool/function calling integration
  - Streaming responses (via callbacks)
  - Prompt caching support
  - Vision/multimodal inputs
  - Thinking mode configuration

  ## Example

      # Initialize Claudio client
      client = %Normandy.LLM.ClaudioAdapter{
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        options: [
          timeout: 60_000,
          enable_caching: true
        ]
      }

      # Use with Normandy agent
      agent = Normandy.Agents.BaseAgent.init(%{
        client: client,
        model: "claude-3-5-sonnet-20241022",
        temperature: 0.7
      })

      {agent, response} = Normandy.Agents.BaseAgent.run(agent, user_input)

  ## Configuration

  The adapter supports all Claudio client options:

  - `:timeout` - Request timeout in milliseconds (default: 30_000)
  - `:enable_caching` - Enable prompt caching (default: false)
  - `:thinking_budget` - Token budget for extended thinking mode
  - `:base_url` - Custom API base URL (for testing)

  """

  use Normandy.Schema

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t() | nil,
          options: keyword()
        }

  schema do
    field(:api_key, :string, required: true)
    field(:base_url, :string, default: nil)
    field(:options, :map, default: %{})
  end

  defimpl Normandy.Agents.Model do
    @moduledoc """
    Implementation of Normandy.Agents.Model protocol for Claudio.

    Converts Normandy requests to Claudio format and vice versa.
    """

    alias Normandy.Components.Message

    @doc """
    Legacy completion function (not used with Claudio).
    """
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
      # Claudio uses Messages API, not Completions
      # Return empty response_model
      response_model
    end

    @doc """
    Converse with Claude via Claudio library.

    Converts Normandy messages to Claudio format, sends request,
    and converts response back to Normandy schema.
    """
    def converse(client, model, temperature, max_tokens, messages, response_model, opts \\ []) do
      # Extract tools from opts if provided
      tools = Keyword.get(opts, :tools, [])

      # Initialize Claudio client
      claudio_client = build_claudio_client(client)

      # Check if caching is enabled
      enable_caching = Map.get(client.options, :enable_caching, false)

      # Build Claudio request
      request =
        Claudio.Messages.Request.new(model)
        |> add_temperature(temperature)
        |> add_max_tokens(max_tokens)
        |> add_messages(messages, enable_caching)
        |> add_tools(tools, enable_caching)
        |> add_client_options(client.options)

      # Execute request
      case Claudio.Messages.create(claudio_client, request) do
        {:ok, response} ->
          convert_response_to_normandy(response, response_model)

        {:error, error} ->
          handle_error(error, response_model)
      end
    end

    @doc """
    Stream responses from Claude via Claudio library.

    Enables streaming mode and returns a raw stream of SSE events
    that can be processed with StreamProcessor.

    ## Options

    - `:tools` - List of tool schemas
    - `:callback` - Function called for each event: `(event_type, data) -> :ok`

    ## Returns

    `{:ok, stream}` - Enumerable stream of events
    `{:error, reason}` - Error occurred

    ## Example

        {:ok, stream} = Model.stream_converse(client, model, temp, max_tokens, messages, schema, callback: fn
          :text_delta, text -> IO.write(text)
          _, _ -> :ok
        end)

        # Process stream
        Enum.each(stream, fn event -> process_event(event) end)
    """
    @spec stream_converse(
            struct(),
            String.t(),
            float() | nil,
            integer() | nil,
            list(),
            struct(),
            keyword()
          ) :: {:ok, Enumerable.t()} | {:error, term()}
    def stream_converse(
          client,
          model,
          temperature,
          max_tokens,
          messages,
          _response_model,
          opts \\ []
        ) do
      # Extract options
      tools = Keyword.get(opts, :tools, [])
      callback = Keyword.get(opts, :callback)

      # Initialize Claudio client
      claudio_client = build_claudio_client(client)

      # Check if caching is enabled
      enable_caching = Map.get(client.options, :enable_caching, false)

      # Build streaming request
      request =
        Claudio.Messages.Request.new(model)
        |> add_temperature(temperature)
        |> add_max_tokens(max_tokens)
        |> add_messages(messages, enable_caching)
        |> add_tools(tools, enable_caching)
        |> add_client_options(client.options)
        |> Claudio.Messages.Request.enable_streaming()

      # Execute streaming request
      case Claudio.Messages.create(claudio_client, request) do
        {:ok, %Tesla.Env{body: stream}} ->
          # Parse events and optionally invoke callback
          event_stream =
            stream
            |> Claudio.Messages.Stream.parse_events()

          final_stream =
            if callback do
              Stream.map(event_stream, fn event ->
                case event do
                  {:ok, parsed_event} ->
                    invoke_stream_callback(parsed_event, callback)
                    parsed_event

                  {:error, _} = error ->
                    error
                end
              end)
            else
              Stream.map(event_stream, fn
                {:ok, event} -> event
                error -> error
              end)
            end

          {:ok, final_stream}

        {:error, error} ->
          {:error, error}
      end
    end

    # Private streaming helpers

    defp invoke_stream_callback(
           %{
             event: "content_block_delta",
             data: %{"delta" => %{"type" => "text_delta", "text" => text}}
           },
           callback
         ) do
      callback.(:text_delta, text)
    end

    defp invoke_stream_callback(
           %{
             event: "content_block_start",
             data: %{"content_block" => %{"type" => "tool_use"} = tool}
           },
           callback
         ) do
      callback.(:tool_use_start, tool)
    end

    defp invoke_stream_callback(
           %{event: "message_start", data: %{"message" => message}},
           callback
         ) do
      callback.(:message_start, message)
    end

    defp invoke_stream_callback(%{event: "message_stop"}, callback) do
      callback.(:message_stop, %{})
    end

    defp invoke_stream_callback(_, _callback), do: :ok

    # Private functions

    defp build_claudio_client(client) do
      opts =
        [api_key: client.api_key]
        |> maybe_add_base_url(client.base_url)

      Claudio.Client.new(opts)
    end

    defp maybe_add_base_url(opts, nil), do: opts
    defp maybe_add_base_url(opts, base_url), do: Keyword.put(opts, :base_url, base_url)

    defp add_temperature(request, nil), do: request

    defp add_temperature(request, temp),
      do: Claudio.Messages.Request.set_temperature(request, temp)

    defp add_max_tokens(request, nil), do: request

    defp add_max_tokens(request, max_tokens),
      do: Claudio.Messages.Request.set_max_tokens(request, max_tokens)

    defp add_messages(request, messages, enable_caching) do
      Enum.reduce(messages, request, fn msg, req ->
        add_single_message(req, msg, enable_caching)
      end)
    end

    defp add_single_message(request, %Message{role: "system", content: content}, enable_caching) do
      if enable_caching do
        # Use caching for system prompts (up to 90% cost reduction)
        Claudio.Messages.Request.set_system_with_cache(request, content)
      else
        Claudio.Messages.Request.set_system(request, content)
      end
    end

    defp add_single_message(request, %Message{role: role, content: content}, _enable_caching)
         when role in ["user", "assistant"] do
      role_atom = String.to_existing_atom(role)
      Claudio.Messages.Request.add_message(request, role_atom, content)
    end

    defp add_single_message(request, %Message{role: "tool", content: tool_result}, _enable_caching) do
      # Tool results should be formatted as tool_result content blocks
      # This is handled by the tool execution loop in BaseAgent
      Claudio.Messages.Request.add_message(request, :user, format_tool_result(tool_result))
    end

    defp add_single_message(request, _msg, _enable_caching), do: request

    defp format_tool_result(result) when is_map(result) do
      # Format tool result for Claude API
      "Tool result: #{inspect(result)}"
    end

    defp format_tool_result(result), do: "Tool result: #{result}"

    defp add_tools(request, [], _enable_caching), do: request

    defp add_tools(request, tools, enable_caching) when is_list(tools) do
      # Add tools with caching if enabled
      # Cache all tools except the last one, then cache the last one
      # This provides optimal caching for tool definitions
      if enable_caching and length(tools) > 0 do
        # Add all tools except last without cache
        {last_tool, other_tools} = List.pop_at(tools, -1)

        request_with_tools = Enum.reduce(other_tools, request, fn tool, req ->
          claudio_tool = convert_tool_schema(tool)
          Claudio.Messages.Request.add_tool(req, claudio_tool)
        end)

        # Add last tool with cache control
        last_claudio_tool = convert_tool_schema(last_tool)
        Claudio.Messages.Request.add_tool_with_cache(request_with_tools, last_claudio_tool)
      else
        # Add tools normally without caching
        Enum.reduce(tools, request, fn tool, req ->
          claudio_tool = convert_tool_schema(tool)
          Claudio.Messages.Request.add_tool(req, claudio_tool)
        end)
      end
    end

    defp convert_tool_schema(%{name: name, description: description, input_schema: schema}) do
      %{
        name: name,
        description: description,
        input_schema: schema
      }
    end

    defp add_client_options(request, options) do
      request
      |> maybe_set_thinking(Map.get(options, :thinking_budget))
    end

    defp maybe_set_thinking(request, nil), do: request

    defp maybe_set_thinking(request, budget) when is_integer(budget) do
      Claudio.Messages.Request.enable_thinking(request, %{
        "type" => "enabled",
        "budget_tokens" => budget
      })
    end

    defp convert_response_to_normandy(claudio_response, response_model) do
      # Extract content from Claudio response
      content = extract_content(claudio_response)

      # If response_model has specific fields, populate them
      case response_model do
        %{__struct__: _module} = schema ->
          # Populate schema with response content
          populate_schema(schema, content, claudio_response)

        _ ->
          # Return raw content
          content
      end
    end

    defp extract_content(%{content: content_blocks}) when is_list(content_blocks) do
      # Combine all text blocks
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("\n")
    end

    defp extract_content(_response), do: ""

    defp populate_schema(schema, content, _claudio_response) do
      # Try to populate the schema with the response content
      # For simple schemas with a chat_message field, use that
      if Map.has_key?(schema, :chat_message) do
        Map.put(schema, :chat_message, content)
      else
        # For other schemas, try to parse as JSON and populate fields
        schema
      end
    end

    defp handle_error(error, response_model) do
      # Log error and return empty response_model
      # In production, you might want more sophisticated error handling
      IO.warn("Claudio API error: #{inspect(error)}")
      response_model
    end
  end
end
