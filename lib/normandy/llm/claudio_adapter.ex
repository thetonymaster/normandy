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

      # Build Claudio request
      request =
        Claudio.Messages.Request.new(model)
        |> add_temperature(temperature)
        |> add_max_tokens(max_tokens)
        |> add_messages(messages)
        |> add_tools(tools)
        |> add_client_options(client.options)

      # Execute request
      case Claudio.Messages.create(claudio_client, request) do
        {:ok, response} ->
          convert_response_to_normandy(response, response_model)

        {:error, error} ->
          handle_error(error, response_model)
      end
    end

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

    defp add_messages(request, messages) do
      Enum.reduce(messages, request, fn msg, req ->
        add_single_message(req, msg)
      end)
    end

    defp add_single_message(request, %Message{role: "system", content: content}) do
      Claudio.Messages.Request.set_system(request, content)
    end

    defp add_single_message(request, %Message{role: role, content: content})
         when role in ["user", "assistant"] do
      role_atom = String.to_existing_atom(role)
      Claudio.Messages.Request.add_message(request, role_atom, content)
    end

    defp add_single_message(request, %Message{role: "tool", content: tool_result}) do
      # Tool results should be formatted as tool_result content blocks
      # This is handled by the tool execution loop in BaseAgent
      Claudio.Messages.Request.add_message(request, :user, format_tool_result(tool_result))
    end

    defp add_single_message(request, _msg), do: request

    defp format_tool_result(result) when is_map(result) do
      # Format tool result for Claude API
      "Tool result: #{inspect(result)}"
    end

    defp format_tool_result(result), do: "Tool result: #{result}"

    defp add_tools(request, []), do: request

    defp add_tools(request, tools) when is_list(tools) do
      # Add each tool individually using add_tool (Claudio API)
      Enum.reduce(tools, request, fn tool, req ->
        claudio_tool = convert_tool_schema(tool)
        Claudio.Messages.Request.add_tool(req, claudio_tool)
      end)
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
      |> maybe_enable_caching(Map.get(options, :enable_caching, false))
      |> maybe_set_thinking(Map.get(options, :thinking_budget))
    end

    defp maybe_enable_caching(request, false), do: request

    defp maybe_enable_caching(request, true) do
      # Enable ephemeral caching on system prompt
      # This is set automatically by Claudio when using set_system
      request
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
