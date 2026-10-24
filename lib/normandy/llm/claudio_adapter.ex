defmodule Normandy.LLM.ClaudioAdapter do
  @moduledoc """
  Adapter for integrating Claudio (Anthropic's Claude API client) with Normandy agents.

  This adapter implements the `Normandy.Agents.Model` protocol to enable
  Normandy agents to use Claude models via the Claudio library.

  ## Features

  - Full Messages API support
  - Tool/function calling integration
  - Streaming responses (`stream/3` returns the events)
  - Prompt caching support
  - Vision/multimodal inputs
  - Thinking mode configuration

  ## Example

      # Initialize Claudio client
      client = %Normandy.LLM.ClaudioAdapter{
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        options: %{
          timeout: 60_000,
          enable_caching: true
        }
      }

      # Use with Normandy agent
      agent = Normandy.Agents.BaseAgent.init(%{
        client: client,
        model: "claude-opus-5-5"
      })

      {:ok, agent, response} = Normandy.Agents.BaseAgent.run(agent, user_input)

  ## Configuration

  The adapter reads these keys from `options` (a map). Nothing below is sent unless set,
  except prompt caching, which is on unless `:enable_caching` is `false`:

  - `:timeout` - Connection timeout in milliseconds (Claudio's default: 60_000)
  - `:recv_timeout` - How long to wait for data once connected, in milliseconds
    (Claudio's default: 120_000); raise it for long thinking or streaming calls
  - `:enable_caching` - Prompt caching (default: `true`; `false` turns it off): an
    explicit breakpoint on the system prompt and the last tool, plus the API's automatic
    breakpoint for the conversation. Keep context-provider output stable across calls, or
    the cache stops at the system prompt. Normandy uses 3 of the API's 4 cache breakpoints
    (system, last tool, automatic); callers who add their own `cache_control` markers can
    add at most one more, or the API rejects the request. A cache write costs 1.25 times
    the input price and a cache read 0.1 times, so an agent that makes one call per
    conversation pays more with it on; a tool loop, which re-sends its prefix on every
    call, pays less
  - `:thinking` - `:adaptive` (Claude 4.6 and later) or `:disabled`
  - `:thinking_display` - `:summarized | :omitted | :updates`; requires `thinking: :adaptive`
  - `:thinking_budget` - Fixed thinking budget in tokens, for models that still accept
    `budget_tokens` (4.6 and earlier, such as Haiku 4.5; Opus 4.7+, 5.x, Sonnet 5 and
    Fable return 400); mutually exclusive with `:thinking`. `thinking: :disabled` also
    returns 400 on Opus 5.5, which always thinks
  - `:thinking_block_binding` - `:error | :drop_block`: what the API does with a replayed
    thinking block whose history changed since it was produced (sends the
    `thinking-binding-controls-2026-08-01` beta). `:drop_block` drops that block and every
    later one instead of rejecting the request. Normandy's own history edits already drop
    the thinking they invalidate (see `Normandy.Components.AgentMemory.drop_thinking/1`);
    this covers edits it can't see, such as a context provider whose output changes the
    system prompt. Requires `thinking: :adaptive` or `:thinking_budget`
  - `:effort` - `:low | :medium | :high | :xhigh | :max`
  - `:speed` - `:fast | :standard` (fast mode research preview)
  - `:inference_geo` - `:global | :us`
  - `:fallbacks` - `:default` or a list of model ids/maps (server-side refusal fallback);
    Normandy rejects it on streaming calls (partial output would reach the callback)
  - `:task_budget` - total tokens for the agentic turn (advisory; API minimum 20,000)
  - `:on_parse_failure` - `:fallback | :error`, what to do when the output still does
    not match the schema after the JSON retries; overrides the `:normandy` app env
    (see `Normandy.LLM.JsonDeserializer`)
  - `:base_url` - Custom API base URL (for testing); the struct's `base_url` field wins
  - `:req_options` - Req options merged into the HTTP client
  - `:structured_outputs` - `false` to use the legacy parse-and-retry path

  Any other key, a non-boolean `:enable_caching`/`:structured_outputs`, or a missing
  `api_key` raises `ArgumentError` when the agent is built (`BaseAgent.init/1`).

  ## Errors

  `converse/3` and `stream/3` return `{:error, %Normandy.LLMError{}}` on failure,
  classified from the Claudio error type (or the HTTP status, for Claudio's generic
  `:api_error`, which it uses for every streaming HTTP error):

  - `:rate_limit` (429), `:overloaded` (529), `:server` (5xx, 408, no status) and
    `:transport` (connection-level failures) are retryable
  - `:authentication` (401), `:permission` (403), `:not_found` (404) and
    `:invalid_request` (other 4xx) are not retryable
  - `:unknown` covers anything else and is not retryable
  - `on_parse_failure: :error` returns `type: :invalid_output`, and so does `:fallback`
    when the schema has no `:chat_message` field to put the raw text in

  Claudio's client-level `retry:` (in `req_options` or the client config) retries HTTP
  failures before Normandy sees them; enabling it together with the agent's `retry`
  multiplies the attempts.

  `validate_options!/1` checks the option combinations and values above once, up front;
  `BaseAgent.init/1` and `ConfigTemplate.rebuild/3` call it for you.

  Which models accept which values is left to the API: an unsupported pairing
  returns the API's 400 through the normal error path.

  ## Structured Outputs

  By default, this adapter uses Anthropic native constrained decoding (structured outputs) to obtain
  schema-valid JSON from the model without relying on the legacy parse-retry loop. The structured
  output path is skipped — and the legacy parse-retry path is used instead — when any of the
  following conditions are true:

  - The kill-switch is off: `config :normandy, :structured_outputs, false` (global) or
    `client.options[:structured_outputs] = false` (per-client, overrides the global setting).
  - The response schema is incompatible with constrained decoding: contains an open `:map` field,
    a non-JSON-Schema scalar type (e.g. `:date`, `:binary`, `:any`), or exceeds the nesting depth
    guard.
  - A tool-loop call (`response_model: %ToolCallResponse{}`) or a stream without
    `request.output_format`. With it, the format (the agent's non-chat output schema) is sent
    as `output_config.format` beside the tools: it constrains the final answer's text, and a
    `tool_use` response is still a tool call. `stream/3` re-sends without the format on a 400
    naming it, as `converse/3` does.
  - Any other call that carries tools.
  - The API answers 400 with a message naming the output format or schema. Any other 400 (such
    as "prompt is too long") is returned as the error, without a second request.

  A response that stops at `max_tokens`, `model_context_window_exceeded` or `refusal` is
  never parsed, re-asked or passed to `:on_parse_failure`, on either path: `converse/3`
  returns the empty response model with that `stop_reason`, and Normandy turns it into
  `{:error, %Normandy.LLMError{type: :max_tokens | :refusal}}`.
  """

  use Normandy.Schema

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.LLM.ClaudioAdapter
  alias Normandy.LLM.Json.Decoder
  alias Normandy.LLM.Json.SchemaBinder
  alias Normandy.LLM.JsonDeserializer
  alias Normandy.LLM.Request
  alias Normandy.LLM.StructuredOutputs
  alias Normandy.LLMError
  alias Normandy.Telemetry.Request, as: TelemetryRequest
  alias Normandy.Telemetry.Usage

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t() | nil,
          options: map(),
          finch: atom() | nil
        }

  schema do
    field(:api_key, :string, required: true)
    field(:base_url, :string, default: nil)
    field(:options, :map, default: %{})
    field(:finch, :any, default: nil)
  end

  # Hides api_key and the credential-bearing options (Normandy.LLM.ClientInspect).
  defimpl Inspect do
    alias Normandy.LLM.ClientInspect

    def inspect(client, opts), do: ClientInspect.inspect(client, opts)
  end

  defimpl Normandy.Agents.Model do
    @moduledoc """
    Implementation of Normandy.Agents.Model protocol for Claudio.

    Converts Normandy requests to Claudio format and vice versa.
    """

    alias Normandy.Components.ContentBlock
    alias Normandy.Components.ContentBlock.Describe
    alias Normandy.Components.ContentBlock.Protocol
    alias Normandy.Components.Message
    alias Normandy.LLMError

    # Stop reasons whose answer is incomplete: cut off (max_tokens, the context
    # window) or withheld (refusal). Claudio parses each to this atom.
    @incomplete_stop_reasons [:max_tokens, :model_context_window_exceeded, :refusal]

    @doc """
    Converse with Claude via the Claudio library.

    Converts the `Normandy.LLM.Request` to a Claudio request, sends it, and returns
    `{:ok, %Normandy.LLM.Response{}}` with `request.response_model` filled in (or the
    answer text when it is `nil`).
    """
    def converse(client, %Request{response_model: nil} = request, opts),
      do: converse_raw(client, request, opts)

    def converse(client, %Request{} = request, opts) do
      case ClaudioAdapter.__structured_schema_for__(client, request) do
        {:ok, json_schema} -> converse_structured(client, request, opts, json_schema)
        :skip -> converse_legacy(client, request, opts, nil)
      end
    end

    defp converse_legacy(client, request, opts, request_kind) do
      claudio_client = build_claudio_client(client)

      case create(
             claudio_client,
             build_request(client, request),
             request.model,
             opts,
             request_kind
           ) do
        # An answer cut off or refused is never parsed or re-asked: the empty response
        # model goes back with its stop reason, and Normandy.LLM.Call makes the error.
        {:ok, %Claudio.Messages.Response{stop_reason: reason} = response}
        when reason in @incomplete_stop_reasons ->
          {:ok, ClaudioAdapter.__incomplete_response__(request, response)}

        {:ok, response} ->
          # Pass context for JSON retry
          context = %{
            client: client,
            request: request,
            json_retries: Keyword.get(opts, :json_retries, 2),
            request_tracker: Keyword.get(opts, :request_tracker)
          }

          {converted, retry_usages} =
            convert_response_to_normandy(response, request.response_model, context)

          # The first response and any JSON retries were billed, even when the call
          # failed; on failure the usage rides on the error.
          usage =
            ClaudioAdapter.add_retry_usages(
              ClaudioAdapter.extract_usage(response),
              retry_usages
            )

          case converted do
            {:error, %LLMError{} = error} ->
              {:error, LLMError.with_usage(error, usage)}

            normalized_response ->
              {:ok, ClaudioAdapter.__response__(normalized_response, response, usage)}
          end

        {:error, error} ->
          handle_error(error)
      end
    end

    defp converse_structured(client, request, opts, json_schema) do
      claudio_client = build_claudio_client(client)

      # The format constrains the answer, so the system prompt leaves out the schema it
      # would repeat (AX-19); a fallback to the legacy path sends it again.
      claudio_request =
        client
        |> build_request(constrained(request))
        |> Claudio.Messages.Request.set_output_format(json_schema)

      case create(claudio_client, claudio_request, request.model, opts, nil) do
        # An answer cut off or refused is never parsed or re-asked: the empty response
        # model goes back with its stop reason, and Normandy.LLM.Call makes the error.
        {:ok, %Claudio.Messages.Response{stop_reason: reason} = response}
        when reason in @incomplete_stop_reasons ->
          {:ok, ClaudioAdapter.__incomplete_response__(request, response)}

        {:ok, response} ->
          context = %{client: client, request: request}

          case handle_structured(response, request.response_model, context) do
            {:error, %LLMError{} = error} ->
              {:error, LLMError.with_usage(error, ClaudioAdapter.extract_usage(response))}

            handled ->
              {:ok,
               ClaudioAdapter.__response__(
                 handled,
                 response,
                 ClaudioAdapter.extract_usage(response)
               )}
          end

        {:error, error} ->
          case ClaudioAdapter.__structured_error_action__(error) do
            :fallback -> converse_legacy(client, request, opts, :structured_fallback)
            :propagate -> handle_error(error)
          end
      end
    end

    # A tool-loop call's text is the constrained final answer, or text beside tool
    # calls: it stays the ToolCallResponse's content, and the turn parses the final
    # answer into the output schema (BaseAgent.convert_turn_output/3), as on the
    # legacy path.
    defp handle_structured(response, %Normandy.Agents.ToolCallResponse{} = schema, _context),
      do: populate_tool_call_response(schema, ClaudioAdapter.extract_content(response), response)

    defp handle_structured(response, response_model, context),
      do: ClaudioAdapter.__handle_structured_response__(response, response_model, context)

    # The answer as text, with no schema deserialization: response_model nil. Used by
    # JsonDeserializer's retry loop so it owns parsing and retrying.
    defp converse_raw(client, request, opts) do
      claudio_client = build_claudio_client(client)

      case create(
             claudio_client,
             build_request(client, request),
             request.model,
             opts,
             Keyword.get(opts, :request_kind)
           ) do
        {:ok, response} ->
          {:ok,
           ClaudioAdapter.__response__(
             ClaudioAdapter.extract_content(response),
             response,
             ClaudioAdapter.extract_usage(response)
           )}

        {:error, error} ->
          handle_error(error)
      end
    end

    # One non-streaming Messages API request, in a [:normandy, :llm, :request] span
    # (Normandy.Telemetry.Request). `kind` is nil for the call's first request.
    defp create(claudio_client, request, model, opts, kind) do
      TelemetryRequest.span(
        Keyword.get(opts, :request_tracker),
        kind,
        %{model: model, provider: :anthropic, stream: false},
        fn -> Claudio.Messages.create(claudio_client, request) end,
        &ClaudioAdapter.__request_outcome__/1
      )
    end

    @doc """
    Stream a response from Claude via the Claudio library.

    Returns `{:ok, stream}`: the SSE events converted to the stream events described in
    `Normandy.Agents.Model` ("Stream events"), ready for
    `Normandy.Components.StreamProcessor`. A transport failure after the stream started
    is an `{:error, reason}` item. Normandy, not this adapter, delivers the events to
    the caller's callback.
    """
    def stream(client, %Request{} = request, _opts) do
      claudio_client = build_claudio_client(client)

      stream_request =
        &(client
          |> build_request(&1, stream: true)
          |> Claudio.Messages.Request.enable_streaming())

      # request.output_format constrains the streamed text as it does a tool-loop
      # call's, and the system prompt then leaves out the schema (AX-19). A 400 naming
      # the output format or its schema re-sends the request without the format and
      # with the schema in the system prompt; any other error is returned.
      result =
        case ClaudioAdapter.__structured_schema_for__(client, request) do
          {:ok, json_schema} ->
            request
            |> constrained()
            |> stream_request.()
            |> Claudio.Messages.Request.set_output_format(json_schema)
            |> open_stream(claudio_client)
            |> retry_stream_without_format(stream_request.(request), claudio_client)

          :skip ->
            open_stream(stream_request.(request), claudio_client)
        end

      case result do
        {:ok, stream} -> {:ok, stream}
        {:error, error} -> {:error, ClaudioAdapter.__to_llm_error__(error)}
      end
    end

    defp open_stream(claudio_request, claudio_client) do
      case Claudio.Messages.create(claudio_client, claudio_request) do
        {:ok, %Req.Response{body: stream}} ->
          {:ok,
           stream
           |> Claudio.Messages.Stream.parse_events()
           |> Stream.map(fn
             {:ok, event} -> to_stream_processor_event(event)
             {:error, _} = error -> error
           end)}

        {:error, _error} = error ->
          error
      end
    end

    defp retry_stream_without_format({:ok, _stream} = ok, _claudio_request, _claudio_client),
      do: ok

    defp retry_stream_without_format({:error, error}, claudio_request, claudio_client) do
      case ClaudioAdapter.__structured_error_action__(error) do
        :fallback -> open_stream(claudio_request, claudio_client)
        :propagate -> {:error, error}
      end
    end

    # Private streaming helpers

    # Claudio's parse_events emits `%{event: "...", data: %{...}}`; `data` is
    # decoded with string keys (deps/claudio/lib/claudio/messages/stream.ex,
    # parse_event/1), and data_get/2 reads that form. Normandy's StreamProcessor pattern-matches
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
        usage: data_get(data, :usage) |> stringify_keys(),
        # Top level, beside delta and usage (after a mid-stream fallback).
        input_transformations: data_get(data, :input_transformations) |> stringify_keys()
      }
    end

    defp to_stream_processor_event(%{event: "message_stop"}), do: %{type: "message_stop"}

    defp to_stream_processor_event(%{event: "ping"}), do: %{type: "ping"}

    defp to_stream_processor_event(%{event: "error", data: data}) do
      %{type: "error", error: data_get(data, :error) || data}
    end

    defp to_stream_processor_event(other), do: other

    defp data_get(data, key) when is_map(data), do: Map.get(data, Atom.to_string(key))

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

    defp build_claudio_client(client), do: ClaudioAdapter.to_claudio_client(client)

    defp add_temperature(request, nil), do: request

    defp add_temperature(request, temp),
      do: Claudio.Messages.Request.set_temperature(request, temp)

    @doc false
    # Public (not `defp`) so tests can exercise the full message pipeline
    # directly without round-tripping through `converse/3` and a live Claudio
    # HTTP client. Not part of the adapter's supported surface.
    #
    # Conversation caching: with `enable_caching`, set Claudio's top-level
    # automatic breakpoint. The API places it on the last cacheable block of any
    # role (tool results included) and moves it forward as the conversation
    # grows. Together with the explicit system and last-tool breakpoints that's 3
    # of the 4 allowed. Normandy marks no message block itself.
    def add_messages(request, messages, enable_caching) do
      ensure_single_leading_system!(messages)

      request =
        if enable_caching,
          do: Claudio.Messages.Request.set_cache_control(request),
          else: request

      case messages do
        [%Message{role: "system"} = system | rest] ->
          request
          |> add_single_message(system, enable_caching)
          |> append_messages(rest)

        _no_system ->
          append_messages(request, messages)
      end
    end

    # One Claudio call for the whole conversation: Request.add_messages/2 appends in
    # time linear in the history (a loop of add_message/3 copies the list each time).
    defp append_messages(request, messages),
      do: Claudio.Messages.Request.add_messages(request, Enum.map(messages, &message_entry/1))

    @doc false
    # Public (not `defp`) so tests can exercise the dispatch branches
    # directly without round-tripping through `converse/3` and a live
    # Claudio HTTP client. Not part of the adapter's supported surface —
    # callers should go through `Normandy.Agents.Model.converse/3`.
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

    def add_single_message(request, message, _enable_caching) do
      {role, content} = message_entry(message)
      Claudio.Messages.Request.add_message(request, role, content)
    end

    # A message as Claudio's `{role, content}`: content blocks become API maps here, so
    # add_messages/2 and add_message/3 get the same entry.
    defp message_entry(%Message{role: role, content: content})
         when role in ["user", "assistant"] and is_list(content) do
      blocks = content |> ensure_non_empty_content!() |> Enum.map(&block_to_claudio/1)
      {String.to_existing_atom(role), blocks}
    end

    # Single ContentBlock struct as content — treat as a one-element list
    # so the wire shape is symmetric with `content: [block]`. Without this,
    # a caller who sets `content: %Image{...}` ships a raw struct to
    # Claudio and the request is malformed at JSON-encode time.
    defp message_entry(%Message{role: role, content: %{__struct__: _} = block})
         when role in ["user", "assistant"] do
      content = if ContentBlock.block?(block), do: [block_to_claudio(block)], else: block
      {String.to_existing_atom(role), content}
    end

    defp message_entry(%Message{role: role, content: content})
         when role in ["user", "assistant"],
         do: {String.to_existing_atom(role), content}

    # List-form tool content: convert ContentBlock structs to Anthropic
    # wire shape. Pre-shaped maps (e.g. from BaseIOSchema.to_json/1) pass
    # through via the `%{} = raw when not is_struct` branch of
    # block_to_claudio/1, preserving the pre-multimodal tool_result path.
    defp message_entry(%Message{role: "tool", content: content}) when is_list(content),
      do: {:user, content |> ensure_non_empty_content!() |> Enum.map(&block_to_claudio/1)}

    # Tool results are serialized via the BaseIOSchema protocol; they go as a user message.
    defp message_entry(%Message{role: "tool", content: content}), do: {:user, content}

    # Caller typos and unsupported roles (e.g. OpenAI's "function") would
    # otherwise silently disappear from the request — the model gets a
    # degraded conversation with no feedback loop. Raise at the boundary.
    defp message_entry(%Message{role: role, turn_id: turn_id})
         when is_binary(role) and role not in ["system", "user", "assistant", "tool"] do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: unrecognized message role #{inspect(role)} " <>
              "(turn_id=#{inspect(turn_id)}). Expected one of: " <>
              ~s("system", "user", "assistant", "tool".)
    end

    defp message_entry(%Message{role: role}) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: message role must be a string, got: " <>
              Describe.type_of(role)
    end

    defp message_entry(other) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: expected a %Normandy.Components.Message{}, got " <>
              Describe.type_of(other)
    end

    # Anthropic takes one top-level system prompt and `set_system/2` replaces
    # it, so a system message anywhere but first would silently overwrite the
    # agent's prompt (e.g. a "system"-role summary in history). Raise instead.
    defp ensure_single_leading_system!(messages) do
      messages
      |> Enum.with_index()
      |> Enum.drop(1)
      |> Enum.find(fn {msg, _index} -> match?(%Message{role: "system"}, msg) end)
      |> case do
        nil ->
          :ok

        {%Message{turn_id: turn_id}, index} ->
          raise ArgumentError,
                "Normandy.LLM.ClaudioAdapter: system message at position #{index} " <>
                  "(turn_id=#{inspect(turn_id)}); only the first message may be a system " <>
                  "message, since a later one would replace the system prompt. " <>
                  ~s(Store summaries and notes as "user" or "assistant" messages.)
      end
    end

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

    defp block_to_claudio(%{__struct__: _} = b) do
      if ContentBlock.block?(b), do: Protocol.to_claudio(b), else: unsupported_block!(b)
    end

    # Pass through any caller-provided pre-shaped block map (e.g. when a
    # caller hand-builds an Anthropic block for a feature Normandy doesn't
    # model yet, like `cache_control`). Plain maps only — structs (which
    # are maps with `__struct__`) must match an explicit clause above so
    # unknown struct kinds fail loudly here rather than shipping malformed
    # wire data to Anthropic.
    defp block_to_claudio(%{} = raw) when not is_struct(raw), do: raw

    defp block_to_claudio(other), do: unsupported_block!(other)

    @spec unsupported_block!(term()) :: no_return()
    defp unsupported_block!(other) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: unsupported content block, got " <>
              "#{Describe.type_of(other)}. " <>
              "Expected a Normandy.Components.ContentBlock.* struct or a " <>
              "pre-shaped Anthropic block map."
    end

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

    # A request whose output the format constrains: its system prompt without the
    # output-schema section.
    defp constrained(%Request{} = request), do: %{request | output_schema_prompt: nil}

    # The one request builder for every call path (legacy, structured, raw
    # retry, streaming), so a setting cannot reach one path and miss another.
    #
    # `max_tokens` is required by the Request struct; a nil fails here instead of being
    # dropped. add_messages/3 takes the system prompt as a leading "system" message, and
    # keeps ensure_single_leading_system!/1: a "system" message in `request.messages`
    # next to `:system` raises.
    defp build_request(client, %Request{} = request, call_opts \\ []) do
      # On unless the client opts out (MIGRATING-2.0.md §38).
      enable_caching = Map.get(client.options, :enable_caching, true)

      Claudio.Messages.Request.new(request.model)
      |> add_temperature(request.temperature)
      |> Claudio.Messages.Request.set_max_tokens(request.max_tokens)
      |> add_messages(
        Request.messages_with_system(%{request | context_prompt: nil}),
        enable_caching
      )
      |> add_context_prompt(request.context_prompt)
      |> add_tools(request.tools, enable_caching)
      |> add_mcp_servers(request.mcp_servers)
      |> add_tool_choice(request.tool_choice)
      |> add_client_options(client.options, call_opts ++ task_budget_opts(request))
    end

    # The context providers' text can change from call to call (a date, user data), so it
    # is a system block of its own after the cached one, with no breakpoint: a change
    # leaves the rest of the system prompt cached (AX-20).
    defp add_context_prompt(claudio_request, nil), do: claudio_request

    defp add_context_prompt(%Claudio.Messages.Request{system: system} = claudio_request, context),
      do:
        Claudio.Messages.Request.set_system(
          claudio_request,
          system_blocks(system) ++ [%{"type" => "text", "text" => context}]
        )

    defp system_blocks(nil), do: []
    defp system_blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
    defp system_blocks(blocks) when is_list(blocks), do: blocks

    # tool_choice is valid only next to tools (the agent's, or an MCP server's
    # mcp_toolset), so a request with none leaves it unset.
    defp add_tool_choice(claudio_request, nil), do: claudio_request

    defp add_tool_choice(%Claudio.Messages.Request{tools: tools} = claudio_request, :none)
         when tools in [nil, []],
         do: claudio_request

    defp add_tool_choice(claudio_request, :none),
      do: Claudio.Messages.Request.set_tool_choice(claudio_request, :none)

    defp task_budget_opts(%Request{task_budget_remaining: nil}), do: []
    defp task_budget_opts(%Request{task_budget_remaining: n}), do: [task_budget_remaining: n]

    defp add_tools(request, [], _enable_caching), do: request

    defp add_tools(request, tools, enable_caching) when is_list(tools) do
      # Add tools with caching if enabled
      # Cache all tools except the last one, then cache the last one
      # This provides optimal caching for tool definitions (the clause above took [])
      if enable_caching do
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

    defp add_client_options(request, options, call_opts),
      do: ClaudioAdapter.__apply_client_options__(request, options, call_opts)

    # {converted, usage of the JSON retries}: only a schema answer is re-asked.
    defp convert_response_to_normandy(claudio_response, response_model, context) do
      content = ClaudioAdapter.extract_content(claudio_response)

      case response_model do
        %Normandy.Agents.ToolCallResponse{} = schema ->
          {populate_tool_call_response(schema, content, claudio_response), []}

        %{__struct__: _module} = schema ->
          populate_standard_schema(schema, content, context)

        _ ->
          {content, []}
      end
    end

    defp populate_tool_call_response(schema, content, claudio_response) do
      # Extract tool_use blocks from Claudio response
      tool_calls = ClaudioAdapter.extract_tool_uses(claudio_response)

      schema
      |> Map.put(:content, content)
      |> Map.put(:tool_calls, tool_calls)
      |> Map.put(:thinking, ClaudioAdapter.extract_thinking(claudio_response))
      |> Map.put(
        :content_blocks,
        Claudio.Messages.Response.to_assistant_content(claudio_response)
      )
      |> Map.put(:stop_reason, claudio_response.stop_reason)
    end

    defp populate_standard_schema(schema, content, context) do
      # Use JsonDeserializer with retry for robust parsing and validation. The request
      # carries the tools and the task budget the retries resend. Each JSON retry is a
      # paid call: its usage comes back beside the result.
      %{client: client, request: request, json_retries: json_retries} = context

      opts = [max_retries: json_retries, request_tracker: context.request_tracker]

      case JsonDeserializer.deserialize_with_usage(content, schema, client, request, opts) do
        {{:ok, validated_schema}, usages} ->
          {validated_schema, usages}

        # An LLM failure during a parse retry is not a parse failure.
        {{:error, %LLMError{}} = error, usages} ->
          {error, usages}

        {{:error, reason}, usages} ->
          {ClaudioAdapter.apply_parse_failure(schema, content, reason, context), usages}
      end
    end

    defp handle_error(error), do: {:error, ClaudioAdapter.__to_llm_error__(error)}
  end

  @doc false
  defdelegate apply_parse_failure(schema, content, reason, context),
    to: Normandy.LLM.ParseFailure,
    as: :apply

  @doc false
  defdelegate __on_parse_failure_policy__(context), to: Normandy.LLM.ParseFailure, as: :policy

  @doc false
  def extract_content(%{content: content_blocks}) when is_list(content_blocks) do
    content_blocks
    |> content_after_last_fallback()
    |> Enum.filter(&(Map.get(&1, :type) == :text))
    |> Enum.map_join("\n", &(Map.get(&1, :text) || ""))
  end

  def extract_content(_response), do: ""

  @doc false
  # Blocks after the last `fallback` block (server-side refusal fallback, Claudio 0.7
  # `Request.set_fallbacks/2`). Earlier blocks came from a model that declined:
  # Normandy must not surface their text or run their tool calls. Unchanged when
  # there is no fallback block.
  @spec content_after_last_fallback(list()) :: list()
  def content_after_last_fallback(blocks) when is_list(blocks) do
    last =
      blocks
      |> Enum.with_index()
      |> Enum.filter(fn {block, _index} -> fallback_block?(block) end)
      |> List.last()

    case last do
      nil -> blocks
      {_block, index} -> Enum.drop(blocks, index + 1)
    end
  end

  defp fallback_block?(block) when is_map(block),
    do: Map.get(block, :type) == :fallback

  defp fallback_block?(_block), do: false

  @doc false
  # Per-call facts that are not token usage, carried as `Response.meta`.
  @spec response_meta(term()) :: map()
  def response_meta(%Claudio.Messages.Response{} = response) do
    served_by =
      case Claudio.Messages.Response.served_by(response) do
        model when is_binary(model) -> %{served_by: model}
        _ -> %{}
      end

    # After a server-side fallback the kept thinking belongs to the fallback model.
    meta =
      case {Claudio.Messages.Response.fallbacks(response), served_by} do
        {[_ | _], %{served_by: model}} -> Map.put(served_by, :fallback_model, model)
        _ -> served_by
      end

    # Thinking blocks the API dropped or let through after their history changed
    # (sent only with :thinking_block_binding's beta).
    meta =
      case response.input_transformations do
        [_ | _] = transformations -> Map.put(meta, :input_transformations, transformations)
        _ -> meta
      end

    # The provider's message id and stop_reason, as a string (e.g. "end_turn").
    meta
    |> put_unless_nil(:response_id, response.id)
    |> put_unless_nil(:finish_reason, stop_reason_string(response.stop_reason))
  end

  def response_meta(_response), do: %{}

  @doc false
  # The %Normandy.LLM.Response{} for a Claudio response; usage is passed in because
  # JSON retries add theirs to the first response's.
  @spec __response__(struct() | String.t(), Claudio.Messages.Response.t(), map() | nil) ::
          Normandy.LLM.Response.t()
  def __response__(content, %Claudio.Messages.Response{} = response, usage) do
    %Normandy.LLM.Response{
      content: content,
      stop_reason: response.stop_reason,
      usage: usage,
      meta: response_meta(response)
    }
  end

  defp stop_reason_string(reason) when is_atom(reason) and reason != nil,
    do: Atom.to_string(reason)

  defp stop_reason_string(reason), do: reason

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  @doc false
  # The served model's thinking and redacted_thinking blocks, in order and in
  # wire shape (string keys), so they can be sent back exactly as received.
  def extract_thinking(%{content: content_blocks}) when is_list(content_blocks) do
    content_blocks
    |> content_after_last_fallback()
    |> ToolCallResponse.thinking_blocks()
  end

  def extract_thinking(_response), do: []

  @doc false
  # The client tool calls Normandy runs: `tool_use` blocks after the last fallback.
  # `mcp_tool_use` and `server_tool_use` blocks were run by the API (an MCP connector,
  # a server tool); their results are already in the response, so they are never
  # dispatched here. They reach the next request in `ToolCallResponse.content_blocks`.
  def extract_tool_uses(%{content: content_blocks}) when is_list(content_blocks) do
    content_blocks
    |> content_after_last_fallback()
    |> Enum.filter(&(Map.get(&1, :type) == :tool_use))
    |> Enum.map(fn tool_use ->
      %Normandy.Components.ToolCall{
        id: Map.get(tool_use, :id),
        name: Map.get(tool_use, :name),
        input: Map.get(tool_use, :input)
      }
    end)
  end

  def extract_tool_uses(_), do: []

  # The first call's usage plus each JSON retry's.
  @doc false
  def add_retry_usages(usage, retry_usages),
    do: Enum.reduce(retry_usages, usage, &Usage.sum(&2, &1))

  @doc false
  def extract_usage(response) when is_map(response),
    do: Map.get(response, :usage)

  def extract_usage(_response), do: nil

  @doc """
  Builds the Claudio HTTP client (a `Req.Request`) for this adapter: the API key,
  `base_url` (when set), `finch` pool and `options[:req_options]` are respected.
  `req_options` is merged with `Req.merge/2`, as in `OpenAICompatibleAdapter`
  (for example `[plug: {Req.Test, MyStub}]` in tests).
  """
  @spec to_claudio_client(t()) :: Req.Request.t()
  def to_claudio_client(%__MODULE__{} = client) do
    options = client.options || %{}

    config =
      %{token: client.api_key, version: "2023-06-01"}
      |> put_present(:finch, client.finch)
      |> put_present(:timeout, Map.get(options, :timeout))
      |> put_present(:recv_timeout, Map.get(options, :recv_timeout))

    req =
      case client.base_url || Map.get(options, :base_url) do
        nil -> Claudio.Client.new(config)
        base_url -> Claudio.Client.new(config, base_url)
      end

    case check_req_options!(client) do
      nil -> req
      req_options -> Req.merge(req, req_options)
    end
  end

  defp check_req_options!(%__MODULE__{options: options}) do
    case Map.get(options, :req_options) do
      nil ->
        nil

      req_options when is_list(req_options) ->
        req_options

      other ->
        raise ArgumentError,
              "ClaudioAdapter.to_claudio_client/1: expected options[:req_options] to be a " <>
                "keyword list of Req options (for example [plug: {Req.Test, MyStub}]), " <>
                "got: #{Describe.type_of(other)}"
    end
  end

  @doc """
  Raises `ArgumentError` when `client.options` can never produce a valid request, and
  returns `client` unchanged otherwise.

  Checks the option combinations (`:thinking` with `:thinking_budget`, `:thinking_display`
  without `thinking: :adaptive`), the values Claudio validates in its own request setters,
  and the shape of `options[:req_options]`. It runs the same option pass real requests
  run, against a placeholder request, so nothing is duplicated and no network is touched.

  `BaseAgent.init/1` and `ConfigTemplate.rebuild/3` call it, so a misconfigured agent
  fails when it is configured rather than on every call, where the retry policy would
  wait through its backoff before surfacing the error.

  The `:fallbacks` check on streaming calls is not made here: it depends on the call,
  so it stays per call.
  """
  @spec validate_options!(t()) :: t()
  def validate_options!(%__MODULE__{} = client) do
    check_api_key!(client.api_key)
    check_option_keys!(client.options)
    check_on_parse_failure!(Map.get(client.options, :on_parse_failure))
    # Builds the Claudio client locally (no request): checks :req_options, and
    # Claudio checks :timeout and :recv_timeout.
    _ = to_claudio_client(client)

    _ =
      __apply_client_options__(
        Claudio.Messages.Request.new("validate-options-placeholder"),
        client.options,
        []
      )

    client
  end

  # Every key `options` may hold; anything else is a typo or an unsupported setting.
  @option_keys [
    :timeout,
    :recv_timeout,
    :base_url,
    :req_options,
    :enable_caching,
    :structured_outputs,
    :on_parse_failure,
    :thinking,
    :thinking_display,
    :thinking_budget,
    :thinking_block_binding,
    :effort,
    :speed,
    :inference_geo,
    :fallbacks,
    :task_budget
  ]

  defp check_on_parse_failure!(nil), do: :ok
  defp check_on_parse_failure!(policy) when policy in [:fallback, :error], do: :ok

  defp check_on_parse_failure!(policy) do
    raise ArgumentError,
          "Normandy.LLM.ClaudioAdapter: client option :on_parse_failure must be :fallback " <>
            "or :error; got #{Describe.type_of(policy)}"
  end

  defp check_api_key!(key) when is_binary(key) and key != "", do: :ok

  defp check_api_key!(key) do
    raise ArgumentError,
          "Normandy.LLM.ClaudioAdapter: api_key must be a non-empty string, got: " <>
            Describe.type_of(key)
  end

  defp check_option_keys!(options) when is_map(options) do
    case Map.keys(options) -- @option_keys do
      [] ->
        :ok

      [key | _] ->
        raise ArgumentError,
              "Normandy.LLM.ClaudioAdapter: unknown client option #{inspect(key)}; " <>
                "supported: #{Enum.map_join(@option_keys, ", ", &inspect/1)}"
    end

    for key <- [:enable_caching, :structured_outputs],
        Map.has_key?(options, key),
        not is_boolean(Map.fetch!(options, key)) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: client option #{inspect(key)} must be a boolean, " <>
              "got: #{Describe.type_of(Map.fetch!(options, key))}"
    end

    :ok
  end

  defp check_option_keys!(options) do
    raise ArgumentError,
          "Normandy.LLM.ClaudioAdapter: client options must be a map, got " <>
            Describe.type_of(options)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  # Applies `client.options` request settings, plus per-call options from the turn
  # loop (`:task_budget_remaining`, `:stream`), to a Claudio request. Public so
  # tests can assert the request shape without an HTTP call; not part of the
  # supported surface. Normandy checks option *combinations* only; values reach
  # Claudio's own ArgumentError and model support reaches the API.
  @spec __apply_client_options__(Claudio.Messages.Request.t(), map(), keyword()) ::
          Claudio.Messages.Request.t()
  def __apply_client_options__(request, options, call_opts \\ []) do
    opt = fn key -> Map.get(options, key) end
    validate_option_combinations!(opt, call_opts)

    request
    |> put_thinking(opt.(:thinking), opt.(:thinking_display), opt.(:thinking_budget))
    |> put_if(
      opt.(:thinking_block_binding),
      &Claudio.Messages.Request.set_thinking_block_binding/2
    )
    |> put_if(opt.(:effort), &Claudio.Messages.Request.set_effort/2)
    |> put_if(opt.(:speed), &Claudio.Messages.Request.set_speed/2)
    |> put_if(opt.(:inference_geo), &Claudio.Messages.Request.set_inference_geo/2)
    |> put_if(opt.(:fallbacks), &Claudio.Messages.Request.set_fallbacks/2)
    |> put_task_budget(opt.(:task_budget), Keyword.get(call_opts, :task_budget_remaining))
  end

  # A flat list of independent checks, one per rule.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_option_combinations!(opt, call_opts) do
    if opt.(:thinking) != nil and opt.(:thinking_budget) != nil do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: client.options :thinking and :thinking_budget are " <>
              "mutually exclusive (:thinking_budget is for models that still accept budget_tokens: " <>
              "4.6 and earlier, such as Haiku 4.5); " <>
              "got thinking: #{Describe.type_of(opt.(:thinking))}, " <>
              "thinking_budget: #{Describe.type_of(opt.(:thinking_budget))}"
    end

    if opt.(:thinking_display) != nil and opt.(:thinking) != :adaptive do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: client.options :thinking_display requires thinking: :adaptive; " <>
              "got thinking: #{Describe.type_of(opt.(:thinking))}"
    end

    if opt.(:thinking_block_binding) != nil and opt.(:thinking) != :adaptive and
         opt.(:thinking_budget) == nil do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: client.options :thinking_block_binding requires " <>
              "thinking: :adaptive or :thinking_budget; got thinking: " <>
              Describe.type_of(opt.(:thinking))
    end

    if opt.(:fallbacks) != nil and Keyword.get(call_opts, :stream, false) do
      raise ArgumentError,
            "Normandy.LLM.ClaudioAdapter: Normandy does not support :fallbacks on streaming calls. " <>
              "The API retries on the same stream, but partial output from the declining model " <>
              "would already have reached the stream callback. Remove client.options :fallbacks " <>
              "or use a non-streaming call"
    end

    :ok
  end

  defp put_thinking(request, nil, _display, nil), do: request

  defp put_thinking(request, :adaptive, display, nil),
    do: Claudio.Messages.Request.enable_adaptive_thinking(request, display: display)

  defp put_thinking(request, :disabled, _display, nil),
    do: Claudio.Messages.Request.disable_thinking(request)

  defp put_thinking(request, nil, _display, budget) when is_integer(budget) do
    Claudio.Messages.Request.enable_thinking(request, %{
      "type" => "enabled",
      "budget_tokens" => budget
    })
  end

  defp put_thinking(_request, thinking, _display, nil) do
    raise ArgumentError,
          "Normandy.LLM.ClaudioAdapter: client.options :thinking must be :adaptive or :disabled; " <>
            "got #{Describe.type_of(thinking)}"
  end

  defp put_thinking(_request, nil, _display, budget) do
    raise ArgumentError,
          "Normandy.LLM.ClaudioAdapter: client.options :thinking_budget must be a positive integer; " <>
            "got #{Describe.type_of(budget)}"
  end

  defp put_if(request, nil, _setter), do: request
  defp put_if(request, value, setter), do: setter.(request, value)

  defp put_task_budget(request, nil, _remaining), do: request

  defp put_task_budget(request, total, nil),
    do: Claudio.Messages.Request.set_task_budget(request, total)

  defp put_task_budget(request, total, remaining),
    do: Claudio.Messages.Request.set_task_budget(request, total, remaining: remaining)

  @doc false
  # Classifies a Claudio failure (spec section 2). A generic :api_error is classified by
  # status: Claudio types every streaming HTTP error as :api_error.
  @spec __to_llm_error__(term()) :: LLMError.t()
  def __to_llm_error__(%LLMError{} = error), do: error

  def __to_llm_error__(%Claudio.APIError{type: type, status_code: status, message: message} = e) do
    {llm_type, retryable?} = classify_api_error(type, status)

    LLMError.new(
      type: llm_type,
      status: status,
      retryable?: retryable?,
      detail: message,
      reason: e
    )
  end

  def __to_llm_error__(%module{} = e)
      when module in [Req.TransportError, Mint.TransportError, Mint.HTTPError] do
    LLMError.transport(e)
  end

  def __to_llm_error__(other), do: LLMError.wrap(other)

  defp classify_api_error(:rate_limit_error, _status), do: {:rate_limit, true}
  defp classify_api_error(:overloaded_error, _status), do: {:overloaded, true}
  defp classify_api_error(:authentication_error, _status), do: {:authentication, false}
  defp classify_api_error(:permission_error, _status), do: {:permission, false}
  defp classify_api_error(:not_found_error, _status), do: {:not_found, false}
  defp classify_api_error(:invalid_request_error, _status), do: {:invalid_request, false}
  defp classify_api_error(_type, status), do: LLMError.classify_status(status)

  @doc false
  # Decides what to do when the structured-outputs call errors. The API refusing the
  # output format or its schema is recoverable via the legacy parse-retry path, which
  # sends no output format, so fall back. Any other error, including other 400s such
  # as "prompt is too long", would fail the legacy call the same way: surface it
  # instead of paying for a second request.
  @spec __structured_error_action__(term()) :: :fallback | :propagate
  def __structured_error_action__(%Claudio.APIError{type: :invalid_request_error} = error) do
    if schema_rejection?(error.message), do: :fallback, else: :propagate
  end

  def __structured_error_action__(_error), do: :propagate

  defp schema_rejection?(message) when is_binary(message),
    do: message =~ ~r/output_format|output_config|schema/i

  defp schema_rejection?(_message), do: false

  @doc false
  # Decides structured-vs-legacy for THIS call, returning the JSON Schema to send as
  # output_config.format. A tool-loop call (response_model %ToolCallResponse{}) and a
  # stream (response_model nil) are constrained by request.output_format alone: the
  # format shapes the final answer's text while tool_use stays available. Any other
  # call with tools takes the legacy path; without tools the response model is the
  # format.
  @spec __structured_schema_for__(t(), Request.t()) :: {:ok, map()} | :skip
  def __structured_schema_for__(client, %Request{response_model: model} = request)
      when model == nil or is_struct(model, ToolCallResponse) do
    case request.output_format do
      nil -> :skip
      format -> StructuredOutputs.schema_for(client, format)
    end
  end

  def __structured_schema_for__(client, %Request{tools: [], response_model: model}),
    do: StructuredOutputs.schema_for(client, model)

  def __structured_schema_for__(_client, %Request{}), do: :skip

  @doc false
  # The %Normandy.LLM.Response{} for an incomplete answer: the request's empty response
  # model, the stop reason and the billed usage. Normandy.LLM.Call turns it into the
  # :max_tokens or :refusal LLMError.
  @spec __incomplete_response__(Request.t(), Claudio.Messages.Response.t()) ::
          Normandy.LLM.Response.t()
  def __incomplete_response__(%Request{response_model: response_model}, response),
    do: __response__(response_model, response, extract_usage(response))

  @incomplete_stop_reasons [:max_tokens, :model_context_window_exceeded, :refusal]

  @doc false
  def __handle_structured_response__(response, response_model, context) do
    content = extract_content(response)

    stop_reason = Map.get(response, :stop_reason)

    case stop_reason do
      # Incomplete (cut off or refused): not parsed, whatever the :on_parse_failure
      # policy; converse/3 never gets here with one (its incomplete clause), so this
      # serves direct callers.
      reason
      when reason in @incomplete_stop_reasons ->
        response_model

      _ ->
        with {:ok, parsed} when is_map(parsed) <-
               Decoder.decode(content, []),
             {:ok, bound} <- SchemaBinder.bind(parsed, response_model, content) do
          bound
        else
          _ ->
            apply_parse_failure(
              response_model,
              content,
              {:structured_output_unparseable, content},
              context
            )
        end
    end
  end

  @doc false
  # The request span's outcome for a `Claudio.Messages.create/2` result.
  @spec __request_outcome__(term()) :: {:ok, map()} | {:error, LLMError.t()}
  def __request_outcome__({:ok, response}) do
    meta = response_meta(response)

    {:ok,
     TelemetryRequest.stop_metadata(
       Map.get(meta, :response_id),
       Map.get(meta, :finish_reason),
       extract_usage(response)
     )}
  end

  def __request_outcome__({:error, error}), do: {:error, __to_llm_error__(error)}
end
