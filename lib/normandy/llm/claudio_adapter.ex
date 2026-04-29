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
          options: keyword(),
          finch: atom() | nil
        }

  schema do
    field(:api_key, :string, required: true)
    field(:base_url, :string, default: nil)
    field(:options, :map, default: %{})
    field(:finch, :any, default: nil)
  end

  defimpl Normandy.Agents.Model do
    @moduledoc """
    Implementation of Normandy.Agents.Model protocol for Claudio.

    Converts Normandy requests to Claudio format and vice versa.
    """

    alias Normandy.Components.Message
    alias Normandy.Components.ContentBlock.Document, as: DocumentBlock
    alias Normandy.Components.ContentBlock.Image, as: ImageBlock
    alias Normandy.Components.ContentBlock.Text, as: TextBlock

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
      # Extract tools and MCP servers from opts if provided
      tools = Keyword.get(opts, :tools, [])
      mcp_servers = Keyword.get(opts, :mcp_servers, nil)

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
        |> add_mcp_servers(mcp_servers)
        |> add_client_options(client.options)

      # Execute request
      case Claudio.Messages.create(claudio_client, request) do
        {:ok, response} ->
          # Pass context for JSON retry
          context = %{
            client: client,
            model: model,
            temperature: temperature,
            max_tokens: max_tokens,
            messages: messages,
            tools: tools
          }

          normalized_response = convert_response_to_normandy(response, response_model, context)
          {normalized_response, extract_usage(response)}

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

      # Execute streaming request - Req returns Req.Response with streaming body
      case Claudio.Messages.create(claudio_client, request) do
        {:ok, %Req.Response{body: stream}} ->
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
                    to_stream_processor_event(parsed_event)

                  {:error, _} = error ->
                    error
                end
              end)
            else
              Stream.map(event_stream, fn
                {:ok, event} -> to_stream_processor_event(event)
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

    # Claudio's parse_events emits `%{event: "...", data: %{...}}` where
    # `data` was decoded with `Poison.decode(..., keys: :atoms)` — so its
    # keys are atoms. Normandy's StreamProcessor pattern-matches
    # `%{type: "...", <shaped-fields>}` directly (atom :type, atom field
    # keys, but the nested content block / delta maps stay string-keyed
    # because StreamProcessor's inner patterns use `%{"type" => ...}`).
    # So we pull fields with atom keys and stringify the nested block/delta
    # payloads so StreamProcessor's downstream patterns match.
    defp to_stream_processor_event(%{event: "message_start", data: data}) do
      %{type: "message_start", message: data_get(data, :message) |> stringify_keys()}
    end

    defp to_stream_processor_event(%{event: "content_block_start", data: data}) do
      %{
        type: "content_block_start",
        content_block: data_get(data, :content_block) |> stringify_keys(),
        index: data_get(data, :index) || 0
      }
    end

    defp to_stream_processor_event(%{event: "content_block_delta", data: data}) do
      %{
        type: "content_block_delta",
        delta: data_get(data, :delta) |> stringify_keys(),
        index: data_get(data, :index) || 0
      }
    end

    defp to_stream_processor_event(%{event: "content_block_stop", data: data}) do
      %{type: "content_block_stop", index: data_get(data, :index) || 0}
    end

    defp to_stream_processor_event(%{event: "message_delta", data: data}) do
      %{
        type: "message_delta",
        delta: data_get(data, :delta) |> stringify_keys(),
        usage: data_get(data, :usage) |> stringify_keys()
      }
    end

    defp to_stream_processor_event(%{event: "message_stop"}), do: %{type: "message_stop"}

    defp to_stream_processor_event(%{event: "ping"}), do: %{type: "ping"}

    defp to_stream_processor_event(%{event: "error", data: data}) do
      %{type: "error", error: data_get(data, :error) || data}
    end

    defp to_stream_processor_event(other), do: other

    # Claudio historically mixes atom-keyed and string-keyed map payloads
    # depending on decode path — read both to stay compatible.
    defp data_get(data, key) when is_map(data) do
      Map.get(data, key) || Map.get(data, Atom.to_string(key))
    end

    defp data_get(_, _), do: nil

    # StreamProcessor's inner patterns (append_text_delta, append_json_delta)
    # key into nested maps with STRING keys (e.g. `%{"type" => "tool_use"}`,
    # `%{"type" => "text_delta", "text" => ...}`). Convert atom-keyed maps
    # to string-keyed maps at any depth so those patterns match.
    defp stringify_keys(nil), do: nil
    defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

    defp stringify_keys(map) when is_map(map) and not is_struct(map) do
      Map.new(map, fn {k, v} ->
        key = if is_atom(k), do: Atom.to_string(k), else: k
        {key, stringify_keys(v)}
      end)
    end

    defp stringify_keys(other), do: other

    # Private functions

    defp build_claudio_client(client) do
      # Build Claudio client with token (not api_key) and version
      # Claudio.Client.new now expects a single map parameter
      config = %{
        token: client.api_key,
        version: "2023-06-01"
      }

      config = if client.finch, do: Map.put(config, :finch, client.finch), else: config

      # base_url is a second parameter, not part of config
      if client.base_url do
        Claudio.Client.new(config, client.base_url)
      else
        Claudio.Client.new(config)
      end
    end

    defp add_temperature(request, nil), do: request

    defp add_temperature(request, temp),
      do: Claudio.Messages.Request.set_temperature(request, temp)

    defp add_max_tokens(request, nil), do: request

    defp add_max_tokens(request, max_tokens),
      do: Claudio.Messages.Request.set_max_tokens(request, max_tokens)

    @doc false
    # Public (not `defp`) so tests can exercise the full message pipeline
    # — auto-cache strategy + per-message dispatch — directly without
    # round-tripping through `converse/7` and a live Claudio HTTP client.
    # Not part of the adapter's supported surface.
    def add_messages(request, messages, enable_caching) do
      messages =
        if enable_caching, do: annotate_last_user_message(messages), else: messages

      Enum.reduce(messages, request, fn msg, req ->
        add_single_message(req, msg, enable_caching)
      end)
    end

    @doc false
    # Public (not `defp`) so tests can exercise the dispatch branches
    # directly without round-tripping through `converse/7` and a live
    # Claudio HTTP client. Not part of the adapter's supported surface —
    # callers should go through `Normandy.Agents.Model.converse/7`.
    # List-form system prompts: convert ContentBlock structs to Anthropic
    # wire shape. When caching is enabled, annotate the last block with
    # `cache_control: {"type": "ephemeral"}` (unless the caller already
    # annotated it). `set_system_with_cache/2` only wraps strings, so
    # multimodal system caching goes through `set_system/2` with
    # pre-annotated wire blocks.
    def add_single_message(request, %Message{role: "system", content: content}, enable_caching)
        when is_list(content) do
      raw = content |> ensure_non_empty_content!() |> Enum.map(&block_to_claudio/1)
      raw = if enable_caching, do: cache_last_block(raw), else: raw
      Claudio.Messages.Request.set_system(request, raw)
    end

    def add_single_message(request, %Message{role: "system", content: content}, enable_caching)
        when is_binary(content) do
      if enable_caching do
        # Use caching for system prompts (up to 90% cost reduction)
        Claudio.Messages.Request.set_system_with_cache(request, content)
      else
        Claudio.Messages.Request.set_system(request, content)
      end
    end

    def add_single_message(
          request,
          %Message{role: role, content: content},
          _enable_caching
        )
        when role in ["user", "assistant"] and is_list(content) do
      ensure_non_empty_content!(content)
      role_atom = String.to_existing_atom(role)
      dispatch_multimodal(request, role_atom, content)
    end

    # Single ContentBlock struct as content — treat as a one-element list
    # so the wire shape is symmetric with `content: [block]`. Without this,
    # a caller who sets `content: %Image{...}` ships a raw struct to
    # Claudio and the request is malformed at JSON-encode time.
    def add_single_message(
          request,
          %Message{role: role, content: %block_mod{} = block},
          _enable_caching
        )
        when role in ["user", "assistant"] and
               block_mod in [TextBlock, ImageBlock, DocumentBlock] do
      role_atom = String.to_existing_atom(role)
      Claudio.Messages.Request.add_message(request, role_atom, [block_to_claudio(block)])
    end

    def add_single_message(request, %Message{role: role, content: content}, _enable_caching)
        when role in ["user", "assistant"] do
      role_atom = String.to_existing_atom(role)
      Claudio.Messages.Request.add_message(request, role_atom, content)
    end

    # List-form tool content: convert ContentBlock structs to Anthropic
    # wire shape. Pre-shaped maps (e.g. from BaseIOSchema.to_json/1) pass
    # through via the `%{} = raw when not is_struct` branch of
    # block_to_claudio/1, preserving the pre-multimodal tool_result path.
    def add_single_message(
          request,
          %Message{role: "tool", content: content},
          _enable_caching
        )
        when is_list(content) do
      raw = content |> ensure_non_empty_content!() |> Enum.map(&block_to_claudio/1)
      Claudio.Messages.Request.add_message(request, :user, raw)
    end

    def add_single_message(
          request,
          %Message{role: "tool", content: content},
          _enable_caching
        ) do
      # Tool results are serialized via BaseIOSchema protocol
      # They come as content blocks, send as user message
      Claudio.Messages.Request.add_message(request, :user, content)
    end

    # Caller typos and unsupported roles (e.g. OpenAI's "function") would
    # otherwise silently disappear from the request — the model gets a
    # degraded conversation with no feedback loop. Raise at the boundary.
    def add_single_message(
          _request,
          %Message{role: role, turn_id: turn_id},
          _enable_caching
        )
        when is_binary(role) and role not in ["system", "user", "assistant", "tool"] do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: unrecognized message role #{inspect(role)} " <>
              "(turn_id=#{inspect(turn_id)}). Expected one of: " <>
              ~s("system", "user", "assistant", "tool".)
    end

    def add_single_message(request, _msg, _enable_caching), do: request

    # Shared non-empty-list guard — called from every list branch of
    # `add_single_message/3` so no role (system/user/assistant/tool) can
    # ship `"content": []` to the provider (Anthropic rejects it). Single
    # source of truth; raising here beats an opaque 400 downstream.
    defp ensure_non_empty_content!([]) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: message content list must be non-empty; " <>
              "use a plain string for simple text content instead."
    end

    defp ensure_non_empty_content!(list) when is_list(list), do: list

    # Opportunistic dispatch: when a content list exactly matches a shape
    # covered by one of Claudio's named helpers, use the helper so intent
    # is preserved in the request builder. Any other shape (multi-block,
    # reversed order, image-alone, cache-annotated, etc.) falls through
    # to the raw-list path, which Claudio's `add_message/3` accepts
    # natively. Empty-list is rejected at every list-branch entry via
    # `ensure_non_empty_content!/1`, so the clauses below never see `[]`.
    #
    # Cache annotations: Claudio's named helpers (`add_message_with_image`
    # etc.) take raw args and rebuild blocks internally, dropping
    # `cache_control`. So we only take the named-helper path when neither
    # block carries one — `cache_control: nil` in the pattern enforces
    # this. Cached blocks always go through the raw-list fallback.
    # Non-empty-string guards mirror `ContentBlock.{Image,Document}.to_claudio/1`:
    # the raw-list fallback (below) ultimately calls those serializers and
    # raises ArgumentError on empty `data`/`media_type`/`url`/`file_id`. The
    # named-helper path here would otherwise ship empty values to Anthropic
    # downstream, asymmetrically letting malformed blocks through.
    defp dispatch_multimodal(request, role, [
           %ImageBlock{
             source: :base64,
             data: data,
             media_type: media_type,
             cache_control: nil
           },
           %TextBlock{text: text, cache_control: nil}
         ])
         when is_binary(data) and data != "" and
                is_binary(media_type) and media_type != "" and
                is_binary(text) do
      Claudio.Messages.Request.add_message_with_image(request, role, text, data, media_type)
    end

    defp dispatch_multimodal(request, role, [
           %ImageBlock{source: :url, url: url, cache_control: nil},
           %TextBlock{text: text, cache_control: nil}
         ])
         when is_binary(url) and url != "" and is_binary(text) do
      Claudio.Messages.Request.add_message_with_image_url(request, role, text, url)
    end

    defp dispatch_multimodal(request, role, [
           %DocumentBlock{source: :file_id, file_id: file_id, cache_control: nil},
           %TextBlock{text: text, cache_control: nil}
         ])
         when is_binary(file_id) and file_id != "" and is_binary(text) do
      Claudio.Messages.Request.add_message_with_document(request, role, text, file_id)
    end

    defp dispatch_multimodal(request, role, blocks) when is_list(blocks) do
      raw = Enum.map(blocks, &block_to_claudio/1)
      Claudio.Messages.Request.add_message(request, role, raw)
    end

    defp block_to_claudio(%TextBlock{} = b), do: TextBlock.to_claudio(b)
    defp block_to_claudio(%ImageBlock{} = b), do: ImageBlock.to_claudio(b)
    defp block_to_claudio(%DocumentBlock{} = b), do: DocumentBlock.to_claudio(b)
    # Pass through any caller-provided pre-shaped block map (e.g. when a
    # caller hand-builds an Anthropic block for a feature Normandy doesn't
    # model yet, like `cache_control`). Plain maps only — structs (which
    # are maps with `__struct__`) must match an explicit clause above so
    # unknown struct kinds fail loudly here rather than shipping malformed
    # wire data to Anthropic.
    defp block_to_claudio(%{} = raw) when not is_struct(raw), do: raw

    defp block_to_claudio(other) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: unsupported content block #{inspect(other)}. " <>
              "Expected a Normandy.Components.ContentBlock.* struct or a " <>
              "pre-shaped Anthropic block map."
    end

    # Conversation-breakpoint cache strategy: when `enable_caching: true`,
    # find the last `role: "user"` message and annotate its final content
    # block with `cache_control`. Anthropic's prompt cache is cumulative,
    # so a breakpoint at the latest user turn caches the entire system +
    # tools + history up to that point.
    #
    # Only multimodal/list-form content (or a single ContentBlock struct)
    # is annotated — plain string user content is left as-is so we don't
    # silently change the wire shape for chat-text callers.
    defp annotate_last_user_message(messages) do
      case last_user_index(messages) do
        nil -> messages
        idx -> List.update_at(messages, idx, &auto_cache_user_message/1)
      end
    end

    defp last_user_index(messages) do
      messages
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {%Message{role: "user"}, idx}, _acc -> idx
        _, acc -> acc
      end)
    end

    # List-form content: convert to wire-shape and cache the last block.
    defp auto_cache_user_message(%Message{content: content} = msg)
         when is_list(content) and content != [] do
      raw = Enum.map(content, &block_to_claudio/1)
      %{msg | content: cache_last_block(raw)}
    end

    # Single ContentBlock struct: treat as a one-element list.
    defp auto_cache_user_message(%Message{content: %mod{} = block} = msg)
         when mod in [TextBlock, ImageBlock, DocumentBlock] do
      %{msg | content: cache_last_block([block_to_claudio(block)])}
    end

    # String, opaque structs (I/O schema, ToolResult), or empty list:
    # leave the message unchanged. The empty-list case is rejected later
    # by `ensure_non_empty_content!/1` in the dispatch path with a clear
    # ArgumentError; we don't want to mask that here.
    defp auto_cache_user_message(msg), do: msg

    # Annotate the last block of a wire-shape list with a default ephemeral
    # cache breakpoint. If the caller already annotated it (via
    # `with_cache/1` on a struct or by hand-building a map with
    # `"cache_control"`), respect the existing annotation.
    defp cache_last_block([]), do: []

    defp cache_last_block(blocks) do
      {last, rest} = List.pop_at(blocks, -1)
      rest ++ [annotate_block(last)]
    end

    # `block_to_claudio/1` passes caller-supplied raw maps through
    # unchanged, so an atom-keyed `:cache_control` from a hand-built block
    # reaches here intact. Match both atom and string key forms — otherwise
    # we'd silently inject a second `"cache_control"` key alongside the
    # caller's, producing a double-keyed block.
    #
    # An explicit nil value (`%{"cache_control" => nil}` or
    # `%{cache_control: nil}`) is treated as "no annotation": presence
    # alone isn't enough, since a JSON-decoded `null` or a `Map.put`
    # pattern can leave nil values that the caller did not intend as a
    # cache marker. Inject the default and clear the nil key so the wire
    # shape carries exactly one `"cache_control"`.
    defp annotate_block(block) when is_map(block) do
      # String key wins when non-nil; otherwise fall back to the atom key
      # (also non-nil). A nil string-keyed value must NOT shadow a real
      # atom-keyed annotation, or callers like
      # `%{"cache_control" => nil, cache_control: %{type: ..., ttl: ...}}`
      # would silently lose the TTL.
      existing =
        case Map.fetch(block, "cache_control") do
          {:ok, nil} -> Map.get(block, :cache_control)
          {:ok, value} -> value
          :error -> Map.get(block, :cache_control)
        end

      if existing != nil do
        block
      else
        block
        |> Map.delete("cache_control")
        |> Map.delete(:cache_control)
        |> Map.put("cache_control", %{"type" => "ephemeral"})
      end
    end

    defp add_tools(request, [], _enable_caching), do: request

    defp add_tools(request, tools, enable_caching) when is_list(tools) do
      # Add tools with caching if enabled
      # Cache all tools except the last one, then cache the last one
      # This provides optimal caching for tool definitions
      if enable_caching and length(tools) > 0 do
        # Add all tools except last without cache
        {last_tool, other_tools} = List.pop_at(tools, -1)

        request_with_tools =
          Enum.reduce(other_tools, request, fn tool, req ->
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

    defp add_mcp_servers(request, nil), do: request
    defp add_mcp_servers(request, []), do: request

    defp add_mcp_servers(request, servers) when is_list(servers) do
      Enum.reduce(servers, request, fn server, req ->
        claudio_server =
          case server do
            %Normandy.MCP.ServerConfig{} ->
              Normandy.MCP.ServerConfig.to_claudio(server)

            %Claudio.MCP.ServerConfig{} ->
              server

            map when is_map(map) ->
              map
          end

        Claudio.Messages.Request.add_mcp_server(req, claudio_server)
      end)
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

    defp convert_response_to_normandy(claudio_response, response_model, context) do
      # Extract content from Claudio response
      content = extract_content(claudio_response)

      # If response_model has specific fields, populate them
      case response_model do
        %{__struct__: _module} = schema ->
          # Populate schema with response content
          populate_schema(schema, content, claudio_response, context)

        _ ->
          # Return raw content
          content
      end
    end

    defp extract_content(%{content: content_blocks}) when is_list(content_blocks) do
      # Combine all text blocks
      # Note: Claudio.Messages.Response uses atom keys (:type, :text) not string keys
      content_blocks
      |> Enum.filter(fn block ->
        Map.get(block, :type) == :text || Map.get(block, "type") == "text"
      end)
      |> Enum.map(fn block ->
        Map.get(block, :text) || Map.get(block, "text") || ""
      end)
      |> Enum.join("\n")
    end

    defp extract_content(_response), do: ""

    defp populate_schema(schema, content, claudio_response, context) do
      # Handle ToolCallResponse specially
      case schema do
        %Normandy.Agents.ToolCallResponse{} ->
          populate_tool_call_response(schema, content, claudio_response)

        _ ->
          populate_standard_schema(schema, content, context)
      end
    end

    defp populate_tool_call_response(schema, content, claudio_response) do
      # Extract tool_use blocks from Claudio response
      tool_calls = extract_tool_uses(claudio_response)

      schema
      |> Map.put(:content, content)
      |> Map.put(:tool_calls, tool_calls)
    end

    defp extract_tool_uses(%{content: content_blocks}) when is_list(content_blocks) do
      content_blocks
      |> Enum.filter(fn block ->
        type = Map.get(block, :type) || Map.get(block, "type")
        type in [:tool_use, :mcp_tool_use, "tool_use", "mcp_tool_use"]
      end)
      |> Enum.map(fn tool_use ->
        type = Map.get(tool_use, :type) || Map.get(tool_use, "type")

        tool_name = Map.get(tool_use, :name) || Map.get(tool_use, "name")

        name =
          cond do
            type in [:mcp_tool_use, "mcp_tool_use"] ->
              server_name =
                Map.get(tool_use, :server_name) || Map.get(tool_use, "server_name")

              if server_name do
                "#{server_name}__#{tool_name}"
              else
                tool_name
              end

            true ->
              tool_name
          end

        %Normandy.Components.ToolCall{
          id: Map.get(tool_use, :id) || Map.get(tool_use, "id"),
          name: name,
          input: Map.get(tool_use, :input) || Map.get(tool_use, "input")
        }
      end)
    end

    defp extract_tool_uses(_), do: []

    defp populate_standard_schema(schema, content, context) do
      # Use JsonDeserializer with retry for robust parsing and validation
      # Extract context parameters
      %{
        client: client,
        model: model,
        temperature: temperature,
        max_tokens: max_tokens,
        messages: messages,
        tools: tools
      } = context

      # Build opts with tools if present
      opts = if tools != [], do: [tools: tools, max_retries: 2], else: [max_retries: 2]

      case Normandy.LLM.JsonDeserializer.deserialize_with_retry(
             content,
             schema,
             client,
             model,
             temperature,
             max_tokens,
             messages,
             opts
           ) do
        {:ok, validated_schema} ->
          validated_schema

        {:error, _reason} when is_binary(content) ->
          # Fallback: treat as plain text if JSON parsing/validation fails after retries
          # This handles cases where the LLM returns plain text instead of JSON
          Map.put(schema, :chat_message, content)

        {:error, _reason} ->
          # Unknown error, return schema unchanged
          schema
      end
    end

    defp extract_usage(response) when is_map(response) do
      Map.get(response, :usage) || Map.get(response, "usage")
    end

    defp extract_usage(_response), do: nil

    defp handle_error(error, response_model) do
      # Log error and return empty response_model
      # In production, you might want more sophisticated error handling
      IO.warn("Claudio API error: #{inspect(error)}")
      response_model
    end
  end
end
