# e2e/otel_bridge.exs — opt-in OTLP export for the e2e scenarios (NORMANDY_E2E_OTLP=1).
#
# Plays the consumer's bridge: Normandy emits only :telemetry events, this turns them into
# OTel spans with the GenAI attributes listed in `Normandy.Telemetry` ("OpenTelemetry GenAI
# mapping") and exports them over OTLP/HTTP to e2e/otel/docker-compose.yml's Tempo.
#
# Process-keyed like `opentelemetry_telemetry`: a span is opened and ended in the process that
# fires its :start / :stop, keyed by `telemetry_span_context` when present (name stack
# otherwise). Point events become span events on the process's current span. Anything the
# bridge cannot match is counted and printed by `report/0` instead of being dropped silently.
defmodule E2E.OtelBridge do
  @moduledoc false

  @spans [
    [:normandy, :workflow, :run],
    [:normandy, :agent, :run],
    [:normandy, :agent, :llm_call],
    [:normandy, :llm, :request],
    [:normandy, :tool, :execute],
    [:normandy, :a2a, :request],
    [:normandy, :turn, :approval]
  ]

  @point_events [
    [:normandy, :tool, :denied],
    [:normandy, :turn, :approval, :expired],
    [:normandy, :turn, :subscriber, :exception],
    [:normandy, :agent, :compaction],
    [:normandy, :agent, :guardrail, :violation],
    [:normandy, :agent, :guardrail, :decision],
    [:normandy, :json_deserializer, :fallback],
    [:normandy, :json_deserializer, :recovery]
  ]

  @handler "e2e-otel-bridge"
  @open_key {__MODULE__, :open}
  @stats __MODULE__.Stats

  def enabled?, do: System.get_env("NORMANDY_E2E_OTLP") not in [nil, "", "0", "false"]

  @doc "Points the SDK at the collector, attaches the handlers and opens the scenario root span."
  def setup(scenario_id) do
    {:ok, _} = Agent.start_link(fn -> %{spans: 0, events: 0, errors: []} end, name: @stats)
    start_export(scenario_id, @stats)

    tracer = :persistent_term.get({__MODULE__, :tracer})

    root =
      :otel_tracer.start_span(:otel_ctx.get_current(), tracer, "e2e " <> scenario_id, %{
        attributes: %{"e2e.scenario" => scenario_id}
      })

    _ = :otel_ctx.attach(:otel_tracer.set_current_span(:otel_ctx.get_current(), root))
    :persistent_term.put({__MODULE__, :root}, root)

    trace_id =
      root |> elem(1) |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    IO.puts("OTEL_TRACE_ID #{trace_id}")
    :ok
  end

  @doc """
  Bridges a peer node's events into the same trace: starts the SDK there and counts into
  the primary's stats, so `report/0` on the primary covers every node. Opens no root span:
  the peer's runs nest under the context the primary passes with each call. `otel_env` is
  the primary's `:opentelemetry` env (the simple processor `start_export/2` points at the
  collector; a peer has only the defaults).
  """
  def setup_peer(scenario_id, primary, otel_env) do
    if List.keymember?(Application.started_applications(), :opentelemetry, 0),
      do:
        raise(
          "setup_peer/3 must run before :opentelemetry starts on #{node()}: its env is read at start"
        )

    Application.put_all_env(opentelemetry: otel_env)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    # The exporter's HTTP client (inets); the primary starts it as a test dependency.
    {:ok, _} = Application.ensure_all_started(:opentelemetry_exporter)
    start_export(scenario_id, {@stats, primary})
  end

  defp start_export(scenario_id, stats) do
    endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

    :ok =
      :otel_simple_processor.set_exporter(:opentelemetry_exporter, %{
        protocol: :http_protobuf,
        endpoints: [endpoint]
      })

    :persistent_term.put({__MODULE__, :scenario}, scenario_id)
    :persistent_term.put({__MODULE__, :stats}, stats)

    # Resolved once: get_application_tracer/1 scans the loaded applications, which took
    # ~2 ms per call here and skewed every span start that called it.
    :persistent_term.put({__MODULE__, :tracer}, :opentelemetry.get_application_tracer(__MODULE__))

    events =
      for(span <- @spans, suffix <- [:start, :stop, :exception], do: span ++ [suffix]) ++
        @point_events

    :ok = :telemetry.attach_many(@handler, events, &__MODULE__.handle/4, nil)
  end

  @doc "Ends the root span (synchronous export) and prints the bridge's counters."
  def report do
    root = :persistent_term.get({__MODULE__, :root})
    _ = :otel_span.end_span(root)
    %{spans: spans, events: events, errors: errors} = Agent.get(@stats, & &1)

    IO.puts(
      "OTEL_BRIDGE " <> Jason.encode!(%{spans: spans, events: events, errors: length(errors)})
    )

    Enum.each(errors, &IO.puts("  otel bridge error: " <> inspect(&1, limit: 8)))
  end

  @doc false
  def handle(event, measurements, meta, _config) do
    {prefix, [phase]} = Enum.split(event, -1)

    cond do
      prefix in @spans and phase == :start ->
        open(prefix, measurements, meta)

      prefix in @spans and phase in [:stop, :exception] ->
        close(prefix, phase, measurements, meta)

      true ->
        point_event(event, measurements, meta)
    end
  rescue
    e -> error(%{event: event, raised: Exception.message(e)})
  end

  # --- spans ---------------------------------------------------------------------------

  # Span times come from the events' monotonic_time (the SDK's own clock), so an OTel
  # span lasts exactly as long as Normandy measured, not as long as the handlers took.
  defp open(prefix, measurements, meta) do
    tracer = :persistent_term.get({__MODULE__, :tracer})
    parent = :otel_ctx.get_current()

    span =
      :otel_tracer.start_span(parent, tracer, span_name(prefix, meta), %{
        start_time: Map.get(measurements, :monotonic_time, :opentelemetry.timestamp()),
        kind: kind(prefix),
        attributes: Map.put(start_attributes(prefix, meta), "e2e.scenario", scenario())
      })

    token = :otel_ctx.attach(:otel_tracer.set_current_span(parent, span))
    key = key(prefix, meta)
    Process.put(@open_key, [{key, span, token} | Process.get(@open_key, [])])
    Agent.update(stats(), __MODULE__, :bump, [:spans])
  end

  defp close(
         [:normandy, :agent, :run] = prefix,
         :exception,
         measurements,
         %{reason: :killed} = meta
       )
       when not is_map_key(meta, :telemetry_span_context) do
    # Synthetic exception for a run a coordinator killed (Normandy.Telemetry "Killed runs"):
    # its span lives in the dead process, so record the kill on the coordinator's span.
    point_event(prefix ++ [:killed], measurements, meta)
  end

  defp close(prefix, phase, measurements, meta) do
    key = key(prefix, meta)
    open = Process.get(@open_key, [])

    case List.keytake(open, key, 0) do
      {{^key, span, token}, rest} ->
        Process.put(@open_key, rest)
        attrs = stop_attributes(prefix, measurements, meta)
        _ = :otel_span.set_attributes(span, attrs)
        set_status(span, prefix, phase, meta)
        now = Map.get(measurements, :monotonic_time, :opentelemetry.timestamp())
        _ = :otel_span.end_span(span, now)
        _ = :otel_ctx.detach(token)

      nil ->
        error(%{
          event: prefix ++ [phase],
          reason: :no_open_span,
          open: Enum.map(open, &elem(&1, 0))
        })
    end
  end

  defp key(prefix, %{telemetry_span_context: ref}), do: {prefix, ref}
  defp key(prefix, _meta), do: {prefix, :no_ref}

  defp set_status(span, _prefix, :exception, meta) do
    _ = :otel_span.set_attribute(span, "error.type", error_type(meta[:reason]))
    _ = :otel_span.set_status(span, :opentelemetry.status(:error, short(meta[:reason])))
  end

  defp set_status(span, [:normandy, :tool, :execute], :stop, %{status: :error} = meta) do
    _ = :otel_span.set_attribute(span, "error.type", to_s(meta[:error_type] || :tool_error))
    _ = :otel_span.set_status(span, :opentelemetry.status(:error, to_s(meta[:error_type])))
  end

  defp set_status(span, [:normandy, :a2a, :request], :stop, %{status: :error} = meta) do
    _ = :otel_span.set_attribute(span, "error.type", to_s(meta[:error_type]))
    _ = :otel_span.set_status(span, :opentelemetry.status(:error, to_s(meta[:error_type])))
  end

  defp set_status(_span, _prefix, _phase, _meta), do: :ok

  defp point_event(event, measurements, meta) do
    attrs =
      meta
      |> Map.drop([:telemetry_span_context, :stacktrace])
      |> Map.merge(measurements)
      |> Map.new(fn {k, v} -> {"normandy." <> Atom.to_string(k), attr(v)} end)
      |> compact()

    span = :otel_tracer.current_span_ctx(:otel_ctx.get_current())
    _ = :otel_span.add_event(span, Enum.map_join(event, ".", &Atom.to_string/1), attrs)
    Agent.update(stats(), __MODULE__, :bump, [:events])
  end

  # --- names and attributes (Normandy.Telemetry "OpenTelemetry GenAI mapping") ----------

  defp span_name([:normandy, :agent, :run], meta),
    do: join("invoke_agent", meta[:agent_name])

  defp span_name([:normandy, :agent, :llm_call], meta), do: join("chat", meta[:model])
  defp span_name([:normandy, :llm, :request], meta), do: join("chat", meta[:model]) <> " request"
  defp span_name([:normandy, :tool, :execute], meta), do: join("execute_tool", meta[:tool_name])

  defp span_name([:normandy, :workflow, :run], meta),
    do: join("invoke_workflow", meta[:workflow_name] || meta[:orchestrator])

  defp span_name([:normandy, :a2a, :request], _meta), do: "a2a.request"
  defp span_name([:normandy, :turn, :approval], _meta), do: "await_approval"

  defp kind([:normandy, :llm, :request]), do: :client
  defp kind([:normandy, :a2a, :request]), do: :server
  defp kind(_), do: :internal

  defp operation([:normandy, :agent, :run]), do: "invoke_agent"
  defp operation([:normandy, :agent, :llm_call]), do: "chat"
  defp operation([:normandy, :llm, :request]), do: "chat"
  defp operation([:normandy, :tool, :execute]), do: "execute_tool"
  defp operation([:normandy, :workflow, :run]), do: "invoke_workflow"
  defp operation(_), do: nil

  defp start_attributes(prefix, meta) do
    common = %{
      "gen_ai.operation.name" => operation(prefix),
      "gen_ai.provider.name" => provider(meta[:provider]),
      "gen_ai.request.model" => to_s(meta[:model]),
      "gen_ai.agent.name" => to_s(meta[:agent_name]),
      "gen_ai.conversation.id" => to_s(meta[:conversation_id]),
      "normandy.turn_id" => to_s(meta[:turn_id]),
      "normandy.session_id" => to_s(meta[:session_id])
    }

    common |> Map.merge(specific_start(prefix, meta)) |> compact()
  end

  defp specific_start([:normandy, :agent, :run], meta),
    do: %{"normandy.resumed" => meta[:resumed]}

  defp specific_start([:normandy, :agent, :llm_call], meta) do
    %{
      "gen_ai.request.stream" => meta[:stream],
      "gen_ai.request.max_tokens" => meta[:max_tokens],
      "gen_ai.request.temperature" => meta[:temperature],
      "gen_ai.request.reasoning.level" => to_s(meta[:effort]),
      "gen_ai.output.type" => if(meta[:structured_output], do: "json"),
      "server.address" => meta[:server_address],
      "normandy.iteration" => meta[:iteration],
      "normandy.purpose" => to_s(meta[:purpose]),
      "normandy.structured_output" => meta[:structured_output]
    }
  end

  defp specific_start([:normandy, :llm, :request], meta) do
    %{
      "gen_ai.request.stream" => meta[:stream],
      "normandy.attempt" => meta[:attempt],
      "normandy.request_kind" => to_s(meta[:request_kind])
    }
  end

  defp specific_start([:normandy, :tool, :execute], meta) do
    %{
      "gen_ai.tool.name" => to_s(meta[:tool_name]),
      "gen_ai.tool.call.id" => to_s(meta[:tool_call_id]),
      "gen_ai.tool.description" => meta[:tool_description],
      "gen_ai.tool.type" => to_s(meta[:tool_type])
    }
  end

  defp specific_start([:normandy, :workflow, :run], meta) do
    %{
      "gen_ai.workflow.name" => if(meta[:workflow_name], do: inspect(meta[:workflow_name])),
      "normandy.orchestrator" => to_s(meta[:orchestrator]),
      "normandy.step_count" => meta[:step_count]
    }
  end

  defp specific_start([:normandy, :a2a, :request], meta),
    do: %{"normandy.a2a.task_id" => to_s(meta[:task_id])}

  defp specific_start([:normandy, :turn, :approval], meta) do
    %{
      "normandy.approval.tool_names" => attr(meta[:tool_names]),
      "normandy.approval.count" => meta[:count]
    }
  end

  defp stop_attributes([:normandy, :agent, :llm_call], _m, meta) do
    %{
      "gen_ai.response.id" => meta[:response_id],
      "gen_ai.response.model" => to_s(meta[:served_by]),
      "gen_ai.response.finish_reasons" => if(meta[:finish_reason], do: [meta[:finish_reason]]),
      "gen_ai.response.time_to_first_chunk" => seconds(meta[:time_to_first_chunk]),
      "normandy.attempts" => meta[:attempts],
      "normandy.json_retries" => meta[:json_retries],
      "normandy.structured_fallback" => meta[:structured_fallback],
      "normandy.tool_call_count" => meta[:tool_call_count]
    }
    |> Map.merge(usage(meta))
    |> Map.merge(usage(failed_usage(meta)))
    |> compact()
  end

  defp stop_attributes([:normandy, :llm, :request], _m, meta) do
    %{
      "gen_ai.response.id" => meta[:response_id],
      "gen_ai.response.finish_reasons" => if(meta[:finish_reason], do: [meta[:finish_reason]])
    }
    |> Map.merge(usage(meta))
    |> Map.merge(usage(failed_usage(meta)))
    |> compact()
  end

  defp stop_attributes([:normandy, :agent, :run], measurements, meta) do
    compact(%{
      "normandy.turn_id" => to_s(meta[:turn_id]),
      "normandy.approval_wait_s" => seconds(measurements[:approval_wait])
    })
  end

  defp stop_attributes([:normandy, :tool, :execute], _m, meta),
    do: compact(%{"normandy.tool.status" => to_s(meta[:status])})

  defp stop_attributes([:normandy, :a2a, :request], _m, meta),
    do: compact(%{"normandy.a2a.status" => to_s(meta[:status])})

  defp stop_attributes([:normandy, :turn, :approval], _m, meta),
    do: compact(%{"normandy.approval.outcome" => to_s(meta[:outcome])})

  defp stop_attributes(_prefix, _m, _meta), do: %{}

  defp usage(meta) when is_map(meta) do
    %{
      "gen_ai.usage.input_tokens" => meta[:input_tokens],
      "gen_ai.usage.output_tokens" => meta[:output_tokens],
      "gen_ai.usage.cache_read.input_tokens" => meta[:cache_read_input_tokens],
      "gen_ai.usage.cache_write.input_tokens" => meta[:cache_write_input_tokens]
    }
    |> compact()
  end

  defp usage(_), do: %{}

  defp failed_usage(%{reason: %{usage_counts: counts}}) when is_map(counts), do: counts
  defp failed_usage(_), do: nil

  defp provider(:anthropic), do: "anthropic"
  defp provider(nil), do: nil
  defp provider(other), do: to_s(other)

  defp error_type(%{__struct__: Normandy.LLMError, type: type}), do: to_s(type)
  defp error_type(%{__struct__: Normandy.TurnError, type: type}), do: to_s(type)
  defp error_type(%{__exception__: true, __struct__: mod}), do: inspect(mod)
  defp error_type({tag, _}) when is_atom(tag), do: to_s(tag)
  defp error_type(tag) when is_atom(tag), do: to_s(tag)
  defp error_type(_), do: "_OTHER"

  defp short(reason),
    do: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 300)

  defp seconds(nil), do: nil

  defp seconds(native) when is_integer(native),
    do: native / System.convert_time_unit(1, :second, :native)

  defp attr(v) when is_binary(v) or is_number(v) or is_boolean(v), do: v
  defp attr(nil), do: nil
  defp attr(v) when is_atom(v), do: to_s(v)

  defp attr(v) when is_list(v),
    do: if(Enum.all?(v, &is_atom/1), do: Enum.map(v, &to_s/1), else: inspect(v, limit: 10))

  defp attr(v), do: inspect(v, limit: 10, printable_limit: 200)

  defp to_s(nil), do: nil
  defp to_s(v) when is_binary(v), do: v
  defp to_s(v) when is_atom(v), do: v |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp to_s(v), do: inspect(v)

  defp join(op, nil), do: op
  defp join(op, name), do: op <> " " <> to_s(name)

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp scenario, do: :persistent_term.get({__MODULE__, :scenario}, "unknown")
  defp stats, do: :persistent_term.get({__MODULE__, :stats})

  # MFA updates, not closures: a peer's update runs on the primary, where a fun from the
  # peer's separately compiled copy of this module may not match.
  @doc false
  def bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))
  @doc false
  def add_error(stats, details), do: %{stats | errors: stats.errors ++ [details]}

  defp error(details) do
    Agent.update(stats(), __MODULE__, :add_error, [Map.put(details, :pid, self())])
  end
end
