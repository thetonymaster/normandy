defmodule Normandy.A2A.Server do
  @moduledoc """
  Exposes Normandy agents as A2A-compatible endpoints.

  Provides logic for building agent cards from Normandy agent configurations
  and handling incoming A2A messages by routing them through the agent.

  This module provides the logic layer only - it does not start an HTTP server.
  Integrate it into your web framework (e.g., Phoenix controller or Plug).

  ## Example

      # Build agent card
      card = Normandy.A2A.Server.build_agent_card(agent_config,
        name: "My Agent",
        description: "Helps with tasks",
        url: "https://myapp.com/a2a",
        version: "1.0.0"
      )

      # Handle incoming message (in your controller), scoped to the caller
      {:ok, task} =
        Normandy.A2A.Server.handle_message(agent_config, a2a_message, conn.req_headers,
          tool_context: %{memory_namespace: "a2a/" <> caller_id}
        )

  ## What the host owns

  This module never sees the HTTP request. Authentication, authorization and the request
  body limit (`Plug.Parsers`' `:length`) belong to your Plug or controller: every caller
  that gets past them reaches the agent and **every tool in `config.toolset`**, whatever
  `build_agent_card/2`'s `:expose_tools` lists (the card only advertises). Expose an agent
  whose tools are safe for every such caller.

  Each call runs on the `config` you pass, so callers share its `tool_context` (and the
  memory namespace in it) unless you pass `handle_message/4`'s `:tool_context` per caller.
  A shared memory namespace lets one caller plant text that every other caller's turns
  read. `:max_text_bytes` (default 100_000) bounds the text a caller can send.
  """

  alias Claudio.A2A.AgentCard
  alias Claudio.A2A.Message
  alias Claudio.A2A.Part
  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Options
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Telemetry.Span
  alias Normandy.Tool
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  @build_agent_card_opts_schema NimbleOptions.new!(
                                  name: [type: :string, required: true, doc: "The agent's name."],
                                  description: [
                                    type: :string,
                                    required: true,
                                    doc: "What the agent does."
                                  ],
                                  url: [
                                    type: :string,
                                    type_doc: "`t:String.t/0`",
                                    doc: "The A2A endpoint URL."
                                  ],
                                  version: [type: :string, doc: "The agent's version."],
                                  provider_url: [type: :string, doc: "The provider's URL."],
                                  provider_org: [
                                    type: :string,
                                    doc:
                                      "The provider's organization (used with `:provider_url`)."
                                  ],
                                  expose_tools: [
                                    type: {:or, [{:list, :string}, {:in, [:all]}]},
                                    default: [],
                                    doc:
                                      "Tool names to list as skills in the public card, or " <>
                                        "`:all`. By default none, so an internal or privileged " <>
                                        "tool is not advertised unless you choose to."
                                  ]
                                )

  @handle_message_opts_schema NimbleOptions.new!(
                                max_text_bytes: [
                                  type: {:or, [:pos_integer, {:in, [nil]}]},
                                  default: 100_000,
                                  doc:
                                    "The most bytes of text the message's parts may hold in " <>
                                      "total; more is `{:error, :too_large}` and the agent does " <>
                                      "not run. `nil` sets no limit."
                                ],
                                tool_context: [
                                  type: {:custom, Normandy.Options, :plain_map, []},
                                  type_doc: "`t:map/0`",
                                  doc:
                                    "Replaces `config.tool_context` for this call, so each " <>
                                      "caller gets its own (its memory namespace, say). Not " <>
                                      "merged: a key you leave out is absent. Default: the " <>
                                      "config's own."
                                ]
                              )

  @doc """
  Builds a `Claudio.A2A.AgentCard` from a Normandy agent configuration.

  Introspects registered tools to generate skill descriptions.

  ## Options

  #{Options.docs(@build_agent_card_opts_schema)}
  """
  @spec build_agent_card(BaseAgentConfig.t(), keyword()) :: Claudio.A2A.AgentCard.t()
  def build_agent_card(%BaseAgentConfig{} = config, opts) do
    opts =
      Options.validate!(opts, @build_agent_card_opts_schema, {__MODULE__, :build_agent_card, 2})

    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)

    card = AgentCard.new(name, description)

    card =
      case Keyword.get(opts, :version) do
        nil -> card
        version -> AgentCard.set_version(card, version)
      end

    card =
      case {Keyword.get(opts, :provider_url), Keyword.get(opts, :provider_org)} do
        {nil, _} -> card
        {url, org} -> AgentCard.set_provider(card, url, org || "")
      end

    card =
      case Keyword.get(opts, :url) do
        nil ->
          card

        url ->
          AgentCard.add_interface(card, url, "jsonrpc+http", "0.3")
      end

    add_tool_skills(card, config.toolset, Keyword.fetch!(opts, :expose_tools))
  end

  @doc """
  Handles an incoming A2A message by routing it through the agent.

  Returns a `Claudio.A2A.Task` with the result as an artifact, or:

    - `{:error, :no_text}` - the message has no text part (file or data parts
      alone are not run as an empty prompt)
    - `{:error, :agent_failed}` - the agent raised or exited. The remote caller
      gets only this; the detail is logged.

  Each call runs on the given `config`: the A2A `context_id` and `task_id` do
  not carry memory between calls.

  Same as `handle_message/3` with no carrier: the request span nests under
  whatever OpenTelemetry context is current in the calling process.
  """
  @spec handle_message(BaseAgentConfig.t(), Claudio.A2A.Message.t()) ::
          {:ok, Claudio.A2A.Task.t()} | {:error, term()}
  def handle_message(%BaseAgentConfig{} = config, %Claudio.A2A.Message{} = message) do
    handle_message(config, message, [], [])
  end

  @doc """
  Like `handle_message/2`, joining the caller's trace from `carrier`.

  `carrier` is the incoming request's headers as `[{name, value}]` (a Plug
  `conn.req_headers` works as is). When it has a valid W3C `traceparent` and
  OpenTelemetry is loaded, the extracted context is attached for the duration
  of the call (and the previous one put back after), so the agent's spans join
  the remote caller's trace. Without one (absent or malformed) the current
  context is left alone. If your HTTP instrumentation already extracted the trace into a
  server span, call `handle_message/2` instead so the agent nests under that
  span.

  Emits a `[:normandy, :a2a, :request]` `Normandy.Telemetry.Span.span/3`. Start metadata:
  `:task_id` (the id of the returned task) and `:agent_name` (`config.name`).
  Stop metadata adds `:status` (`:ok` or `:error`) and, on error, `:error_type`
  (`:no_text`, `:too_large` or `:agent_failed`). No message content is included.

  Same as `handle_message/4` with no options.
  """
  @spec handle_message(BaseAgentConfig.t(), Claudio.A2A.Message.t(), [{String.t(), String.t()}]) ::
          {:ok, Claudio.A2A.Task.t()} | {:error, term()}
  def handle_message(%BaseAgentConfig{} = config, %Claudio.A2A.Message{} = message, carrier)
      when is_list(carrier) do
    handle_message(config, message, carrier, [])
  end

  @doc """
  Like `handle_message/3`, with options.

  Returns `{:error, :too_large}` when the message's text parts hold more than
  `:max_text_bytes` bytes in total: the agent does not run, nothing is logged, and the
  request span's stop metadata has `error_type: :too_large`.

  ## Options

  #{Options.docs(@handle_message_opts_schema)}
  """
  @spec handle_message(
          BaseAgentConfig.t(),
          Claudio.A2A.Message.t(),
          [{String.t(), String.t()}],
          keyword()
        ) :: {:ok, Claudio.A2A.Task.t()} | {:error, term()}
  def handle_message(%BaseAgentConfig{} = config, %Claudio.A2A.Message{} = message, carrier, opts)
      when is_list(carrier) do
    opts =
      Options.validate!(opts, @handle_message_opts_schema, {__MODULE__, :handle_message, 4})

    config =
      case Keyword.fetch(opts, :tool_context) do
        {:ok, tool_context} -> %{config | tool_context: tool_context}
        :error -> config
      end

    token =
      carrier
      |> Enum.map(fn {name, value} -> {to_string(name), value} end)
      |> trace_ctx()
      |> OtelCtx.attach()

    try do
      request_span(config, message, Keyword.fetch!(opts, :max_text_bytes))
    after
      OtelCtx.detach(token)
    end
  end

  # Only a carrier that names a valid parent replaces the current context:
  # extracting from headers without one would detach the request from any span
  # the caller (e.g. HTTP instrumentation) already made current. `extract/1` is
  # nil for a malformed `traceparent`, and `attach(nil)` is a no-op.
  defp trace_ctx(carrier) do
    if Enum.any?(carrier, fn {name, _} -> String.downcase(name) == "traceparent" end) do
      OtelCtx.extract(carrier)
    end
  end

  defp request_span(config, message, max_text_bytes) do
    task_id = generate_task_id()
    metadata = %{task_id: task_id, agent_name: config.name}

    Span.span([:normandy, :a2a, :request], metadata, fn ->
      result =
        if too_large?(message, max_text_bytes),
          do: {:error, :too_large},
          else: run_text(config, message_text(message), task_id)

      {result, Map.merge(metadata, stop_status(result))}
    end)
  end

  defp stop_status({:ok, _task}), do: %{status: :ok}
  defp stop_status({:error, reason}), do: %{status: :error, error_type: reason}

  defp run_text(_config, "", _task_id), do: {:error, :no_text}
  defp run_text(config, text, task_id), do: run_agent(config, text, task_id)

  # Summed per part before anything is joined or copied.
  defp too_large?(_message, nil), do: false

  defp too_large?(message, max_bytes) do
    message.parts
    |> Enum.reduce(0, fn part, total ->
      case Map.get(part, :text) do
        text when is_binary(text) -> total + byte_size(text)
        _ -> total
      end
    end)
    |> Kernel.>(max_bytes)
  end

  defp message_text(message) do
    message.parts
    |> Enum.map_join("\n", fn part -> Map.get(part, :text) || "" end)
    |> String.trim()
  end

  defp run_agent(config, text, task_id) do
    # Build user input matching the agent's input schema
    user_input =
      case config.input_schema do
        %{chat_message: _} -> %{chat_message: text}
        _ -> text
      end

    try do
      {_updated_config, response} = BaseAgent.run!(config, user_input)

      # Convert response to A2A task
      response_text = extract_response_text(response)

      task = %Claudio.A2A.Task{
        id: task_id,
        status: %{
          state: :completed,
          message: Message.new(:agent, [Part.text(response_text)]),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        },
        artifacts: [
          %Claudio.A2A.Artifact{
            artifact_id: "result-1",
            name: "response",
            parts: [Part.text(response_text)]
          }
        ]
      }

      {:ok, task}
    rescue
      error -> agent_failed(:error, error, __STACKTRACE__)
    catch
      kind, reason when kind in [:exit, :throw] -> agent_failed(kind, reason, __STACKTRACE__)
    end
  end

  # The remote caller is outside this system: it gets a generic error, and the log gets
  # the kind, the exception module and the stacktrace with arities only
  # (TurnError.format_raised/3): never a message, a thrown term or an exit reason.
  defp agent_failed(kind, reason, stacktrace) do
    require Logger

    Logger.error(
      "A2A Server handle_message: the agent failed: " <>
        TurnError.format_raised(kind, reason, stacktrace)
    )

    {:error, :agent_failed}
  end

  defp add_tool_skills(card, nil, _expose), do: card

  defp add_tool_skills(card, %Toolset{} = registry, expose) do
    registry
    |> Toolset.list()
    |> Enum.filter(&(expose == :all or Tool.name(&1) in expose))
    |> Enum.reduce(card, fn tool, acc ->
      AgentCard.add_skill(acc, Tool.name(tool), Tool.description(tool))
    end)
  end

  defp extract_response_text(response) when is_binary(response), do: response

  # Anything else goes out as the schema's JSON (its declared fields only), never
  # inspect/1 output, which would show the remote caller internal metadata. A
  # value with no BaseIOSchema encoding raises, and the caller gets :agent_failed.
  defp extract_response_text(response) when is_map(response) do
    cond do
      Map.has_key?(response, :chat_message) -> to_string(response.chat_message)
      Map.has_key?(response, :content) -> to_string(response.content)
      true -> BaseIOSchema.to_json(response)
    end
  end

  defp extract_response_text(response), do: BaseIOSchema.to_json(response)

  defp generate_task_id do
    "task-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
