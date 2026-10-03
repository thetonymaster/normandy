defmodule Normandy.Telemetry do
  @moduledoc ~S"""
  The catalogue of every `:telemetry` event Normandy emits.

  This module has no functions. It is documentation, and `test/telemetry/catalogue_test.exs`
  keeps it honest: the test scans `lib/` for emitted event names and fails when an
  event is emitted but not listed here, or listed here but not emitted. Each event
  below has a `###` heading whose code span is parsed by that test (`:a | :b` as the
  last element means one event per alternative), so keep that shape when you add one.

  Conventions that hold for all events:

    * Durations and `monotonic_time` are in native time units; convert with
      `System.convert_time_unit/3`. Fields named `*_ms` say so.
    * The keys Normandy adds never carry message, prompt or output content. The
      `:exception` `reason` is the raw error term and may embed provider or parse
      details. Keys with no value are left out of the map, except where a key is described
      as "always present".
    * Metadata keys are snake_case atoms, not dotted semconv names. The mapping to
      OpenTelemetry GenAI attributes is in "OpenTelemetry GenAI mapping" below.
    * Spans follow `:telemetry.span/3`: `:start` has `system_time` and `monotonic_time`
      measurements, `:stop` and `:exception` have `duration` and `monotonic_time`.
      `:exception` metadata adds `kind` (`:error | :exit | :throw`), `reason` and
      `stacktrace`, and each event of one span shares `telemetry_span_context`.
    * The ids below appear on run, llm_call, request and tool events when known:
      `turn_id` (the memory turn id), `session_id` (set by `Turn.Server`) and
      `conversation_id` (the session id; there is no other conversation notion).

  ## Spans

  ### `[:normandy, :agent, :run, :start | :stop | :exception]`

  One agent run: `BaseAgent.run/2`, `run_with_tools/2`, `stream_response/3`,
  `stream_with_tools/3`, and each turn of `Turn.Server` (which emits these by hand;
  see "Turn.Server" below). It is the root of the agent's span tree: llm_call and
  tool spans run inside it.

    * Start metadata: `model`, `agent_name` (always present, may be `nil`), `provider`
      (`:anthropic`, `:openai_compatible`, or `client.options[:provider]`; omitted when
      unknown), `turn_id` (only when known at start: `Turn.Server` knows it, `BaseAgent`
      admits input inside the span), `session_id`, `conversation_id`.
    * Stop metadata: the start keys, plus `turn_id` from the finished run.
    * Turn.Server only: stop and exception measurements add `approval_wait` (see
      "Approval wait"); start metadata carries `resumed: true` for a resumed durable turn.
    * `:exception` from `Turn.Server` for rejected input has `reason: {:rejected, exception}`.

  A run `:exception` may be synthetic: see "Killed runs".

  ### `[:normandy, :agent, :llm_call, :start | :stop | :exception]`

  One LLM call of a run (an iteration of the tool loop), covering all the provider
  requests behind it (retries, JSON parse retries, the structured-outputs fallback).
  `Normandy.Context.Summarizer` emits one per summary request too (compaction runs it
  inside the run), so a run's token totals include its summaries.

    * Start metadata: `model`, `iteration` (1-based; absent on a summary call),
      `purpose` (`:summary`, only on a summary call), `agent_name`, the ids, `stream`
      (boolean, always present), `structured_output` (boolean, always present),
      `provider`, `max_tokens`, `temperature` (only when set; Opus 4.7+ rejects it),
      `effort`, `server_address` (host of the client's base URL; absent when the
      client uses its library default).
    * Stop metadata adds:
      `has_tool_calls` (boolean), `tool_call_count`;
      `usage`, the raw provider usage map, exactly as reported;
      the normalized token counts `input_tokens` (for Anthropic it includes cache
      reads and writes; for OpenAI-shaped usage it equals `prompt_tokens`),
      `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens`, each
      only when the provider reported it (see `Normandy.Telemetry.Usage`);
      `response_id`; `finish_reason` (always a string, e.g. `"end_turn"`, `"stop"`);
      `served_by` (the model that answered, after a server-side fallback);
      `input_transformations`; `attempts` (provider requests made), `json_retries`,
      `structured_fallback` (boolean);
      `time_to_first_chunk`, streaming only.
    * `time_to_first_chunk` is stop **metadata**, not a measurement, because
      `:telemetry.span/3` fixes the stop measurements. It is in native units, measured
      from the start of the attempt that delivered the first chunk (retry backoff is not
      counted), and counts text deltas, thinking deltas and tool-use starts. It is
      absent when the stream delivered none.
    * `:exception`: `reason` is the `%Normandy.LLMError{}`. A failed call still bills
      tokens, so read them from `metadata.reason.usage` (raw) and
      `metadata.reason.usage_counts` (normalized), `nil` when nothing was billed.
      On streaming calls the failure is thrown as `{:stream_turn_error, error}`.

  ### `[:normandy, :llm, :request, :start | :stop | :exception]`

  One provider request inside an llm_call. A `converse/7` can make several (the
  structured-outputs 400 fallback, JSON parse retries); BaseAgent's own retries are
  separate requests too. This is a different event from the llm_call span, and it is
  new (there has never been an `[:normandy, :llm, :call]` event).

    * Emitted by the bundled adapters (`ClaudioAdapter`, `OpenAICompatibleAdapter`) for
      non-streaming calls and by `BaseAgent` for each stream attempt. A third-party
      `Normandy.Agents.Model` emits none unless it calls `Normandy.Telemetry.Request.span/5`
      with the `:request_tracker` option it receives; llm_call's `attempts` then falls
      back to the number of `converse/7` calls.
    * Start metadata: `model`, `provider`, `stream`, `attempt` (1-based across the whole
      llm_call), `request_kind` (`:initial | :retry | :json_retry | :structured_fallback`;
      the key is not `kind`, which the exception event uses for the error class), the ids
      and `agent_name` when known.
    * Stop metadata adds `status: :ok`, `response_id`, `finish_reason` (string) and this
      request's normalized token counts, each when known.
    * `:exception`: `kind: :error`, `reason` is the `%Normandy.LLMError{}`, `stacktrace`
      is `[]` when the request returned the error instead of raising.

  ### `[:normandy, :tool, :execute, :start | :stop | :exception]`

  One tool execution, after the call passed policy, budget and hooks.

    * Start metadata: `tool_name`, `agent_name` (always present), `tool_type`
      (`:extension` for an MCP-wrapped tool, `:function` otherwise), `tool_call_id`,
      `tool_description` (when the tool defines one; a raising `tool_description/1`
      just leaves it out), the ids.
    * Stop metadata adds `status` (`:ok | :error`) and, for a failed execution,
      `error_type` (`:exception | :exit | :timeout | :tool_error | :invalid_result`).
      The model sees the same `{:error, message}`; tool failures are returned, not
      raised, so they usually end in `:stop` with `status: :error`.

  ### `[:normandy, :workflow, :run, :start | :stop | :exception]`

  A multi-agent run: `Workflow.execute/1`, and the entry points of
  `SequentialOrchestrator` (`execute/3`, `execute_with_messages/3`),
  `ParallelOrchestrator` (`execute/2`, `execute_same_input/3`) and
  `HierarchicalCoordinator` (`execute/3`, `execute_with_tasks/3`). Agent runs started
  inside nest under it, because the coordinators carry the OTel context into the tasks
  they spawn.

    * Metadata: `orchestrator` (`:workflow | :sequential | :parallel | :hierarchical`),
      `step_count`, and for DSL workflows `workflow_name` (the module).
    * Not wrapped: `ParallelOrchestrator.execute_stream/2` (a lazy stream has no single
      extent) and the `Reactive` combinators. Their agent runs still nest under the
      caller's current span.

  ### `[:normandy, :a2a, :request, :start | :stop | :exception]`

  `A2A.Server.handle_message/3` handling one agent-to-agent message.

    * Start metadata: `task_id`, `agent_name`.
    * Stop metadata adds `status` (`:ok | :error`) and, on error, `error_type` (`:no_text` or
      `:agent_failed`).
    * Parenting: when the carrier passed to `handle_message/3` has a valid W3C
      `traceparent`, the request span (and the agent run inside it) joins that trace.

  ### `[:normandy, :turn, :approval, :start | :stop]`

  One park of a durable turn awaiting a tool-approval decision (`Turn.Server` only,
  hand-emitted; both events share `telemetry_span_context`).

    * Start metadata: `session_id`, `tool_names`, `count`, plus the run's ids (`turn_id`,
      `conversation_id`).
    * Stop metadata adds `outcome`: `:approved | :rejected | :mixed | :expired |
      :terminated` (`:terminated` when the server stops while parked). `duration` is the
      wait.
    * There is no `:exception` event.

  ## Events

  ### `[:normandy, :tool, :denied]`

  A tool call answered without running its tool. Measurement `count: 1`. Metadata:
  `tool_name`, `agent_name`, `reason` (`:policy | :budget | :hook_halt |
  :approval_expired | :approval_rejected`), `tool_call_id`, `rule_id` (the policy rule,
  when known), the ids. Emitted by `Dispatch` and by `Turn.Server` for rejected or
  expired approvals, so every denial has one shape.

  ### `[:normandy, :turn, :approval, :expired]`

  A parked batch whose approval window closed with no decision. Measurement
  `count` (parked calls). Metadata: `session_id`, `mode` (`:continue | :fail`),
  `timeout_ms`, `tool_names`, plus the run's ids (`turn_id`, `conversation_id`). Each call also gets a `[:normandy, :tool, :denied]`, and the
  approval span stops with `outcome: :expired`.

  ### `[:normandy, :turn, :subscriber, :exception]`

  A `Turn.Server` `:subscriber` function raised, exited or threw; the turn continues.
  Measurement `count: 1`. Metadata: `session_id`, `event` (the subscriber event name),
  `kind`. This is a plain event, not a span.

  ### `[:normandy, :agent, :compaction]`

  Every run's compaction step, including a `Compactor.NoOp`. Measurements: whichever of
  `tokens_before`, `tokens_after`, `tokens_removed` the compactor reported. Metadata:
  `agent_name`, `model`, `strategy`, `compacted` (boolean), `error`, `reason`.

  ### `[:normandy, :agent, :guardrail, :violation]`

  One per guardrail violation set. Measurement `count` (violations). Metadata: `stage`,
  `agent_name`, `guards` (modules), `violations`. The violation maps describe the rule
  that failed; they do not include the offending text.

  ### `[:normandy, :agent, :guardrail, :decision]`

  The admission decision of `BaseAgent.admit/2,3`, only when guardrails are configured.
  Measurement `count`. Metadata: `stage` (`:input`), `outcome` (`:admit | :block |
  :error`), `agent_name`, `guards`, `violations`.

  ### `[:normandy, :json_deserializer, :fallback]`

  The JSON parse of a model response failed and a fallback ran. Measurement `count: 1`.
  Metadata: `reason` (the failure's tag), `content_bytes`. Never the output itself.

  ### `[:normandy, :json_deserializer, :recovery]`

  A truncated string was repaired and the parse succeeded. Measurement `recovered: 1`.
  Metadata: `strategy`, `byte_size_before`, `byte_size_after`.

  ## Turn.Server

  `Turn.Server` is a `:gen_statem` whose turn spans several callbacks, so it emits the
  run events by hand instead of through `:telemetry.span/3`.

    * Parenting: `run/2` carries the caller's OTel context in the call, and the server
      attaches it around the run `:start`, so the run nests under the caller's span.
      llm_call and tool spans, which run in the server's tasks, nest under the run.
    * Terminate: a server that stops with a turn in flight through a callback stop or
      `:gen_statem.stop/3` emits a run `:exception` with `kind: :exit` in `terminate/3`.
      The server does not trap exits, so `:kill`, a supervisor's `Process.exit/2` or a
      linked process dying run no callback and emit nothing.
    * Resumed durable turns: a restarted server that resumes a turn emits a run `:start`
      with `resumed: true`, parented under the original caller's context, which was saved
      with the turn as a W3C carrier. It is a sibling of the original run in the same
      trace, not a child of it.
    * `approve/2` carries the approver's OTel context; it is current while the approval
      `:stop` and the denied events of rejected calls fire.

  ## Approval wait

  A turn that parks for approval is still one run span. The run's `:stop` and
  `:exception` measurements carry `approval_wait`: the sum of every park's duration in
  that turn (native units, `0` if never parked), so a consumer can separate waiting
  for a human from work. Each park is also its own `[:normandy, :turn, :approval]`
  span. `BaseAgent.run/2` never parks, so its run events have no `approval_wait`.

  ## Killed runs

  Coordinators that kill an agent task (`Reactive.race/some/all`,
  `ParallelOrchestrator.execute/execute_stream`, `Batch.Processor.process_batch`)
  emit a synthetic `[:normandy, :agent, :run, :exception]` for it, in the coordinator
  process, with the caller's OTel context attached. It has `reason: :killed`,
  `kind: :exit`, `stacktrace: []`, no `telemetry_span_context`, and the same run
  metadata as a live run's `:start` (`model`, `agent_name`, `provider`, and the session
  ids when set), minus `turn_id`. Consequences:

    * A handler can see this `:exception` with no matching `:start` (the start fired in
      the killed process).
    * A process-keyed bridge such as `opentelemetry_telemetry`, which keeps its open
      spans in the process dictionary of the process that fired `:start`, cannot close
      that span from the coordinator, so the killed run's span is never exported. This
      is believed from that library's design; it is **not verified** (it is not a
      dependency here). Normandy's own test bridge, which works the same way, drops the
      event. A handler that wants the kill on the trace can record it from this event
      under the current (caller's) span.
    * The llm_call and tool spans that were open inside the killed run stay open;
      nothing emits their `:stop` or `:exception`.
    * Not emitted for agent pids, for tasks that finished their run before the kill, or
      for tasks `Task.async_stream` shuts down when the consumer halts early
      (`Reactive.all` with `fail_fast`). A short window between a run's
      `:stop` and its completion mark can still produce a late synthetic `:exception`.

  See `Normandy.Telemetry.KilledRun` for the details.

  ## OpenTelemetry GenAI mapping

  Normandy depends on no OTel library (the packages are test-only). A bridge in your
  application turns these events into spans. The table says which Normandy key feeds
  which GenAI semantic-convention attribute. Checked against semantic-conventions-genai
  `main` on 2026-10-03. All GenAI attributes are **Development** stability, so names and
  allowed values can still change.

  | Semconv attribute | Source |
  |---|---|
  | `gen_ai.operation.name` | derived from the event: `invoke_agent` for run, `chat` for llm_call and request, `execute_tool` for tool execute, `invoke_workflow` for workflow run |
  | `gen_ai.provider.name` | `provider`, mapped by the bridge: `:anthropic` is `"anthropic"`; `:openai_compatible` is `"openai"` only for OpenAI itself, otherwise a custom value (the spec allows one when no well-known value applies) |
  | `gen_ai.workflow.name` | workflow run `workflow_name` (the module, as a string) |
  | `gen_ai.request.stream` | llm_call start `stream` |
  | `gen_ai.request.reasoning.level` | llm_call start `effort` (the exact string sent to the provider) |
  | `gen_ai.output.type` | `"json"` when llm_call start `structured_output` is `true` |
  | `gen_ai.request.model` | `model` |
  | `gen_ai.request.max_tokens` | llm_call start `max_tokens` |
  | `gen_ai.request.temperature` | llm_call start `temperature` |
  | `gen_ai.response.id` | stop `response_id` |
  | `gen_ai.response.model` | stop `served_by` |
  | `gen_ai.response.finish_reasons` | stop `finish_reason`, as a one-element list |
  | `gen_ai.usage.input_tokens` | stop `input_tokens` |
  | `gen_ai.usage.output_tokens` | stop `output_tokens` |
  | `gen_ai.usage.cache_read.input_tokens` | stop `cache_read_input_tokens` |
  | `gen_ai.usage.cache_write.input_tokens` | stop `cache_write_input_tokens` |
  | `gen_ai.tool.name` | tool `tool_name` |
  | `gen_ai.tool.call.id` | tool `tool_call_id` |
  | `gen_ai.tool.description` | tool `tool_description` |
  | `gen_ai.tool.type` | tool `tool_type` (`:function` is `"function"`, `:extension` is `"extension"`) |
  | `gen_ai.agent.name` | `agent_name` |
  | `gen_ai.conversation.id` | `conversation_id` |
  | `error.type` | `:exception` `reason`: an `LLMError`'s `type`, else the exception module or the term's tag; tool `error_type` |
  | `gen_ai.response.time_to_first_chunk` | llm_call stop `time_to_first_chunk`; the attribute is a double in **seconds**, so the bridge converts from native units with `System.convert_time_unit/3` (or `/ System.convert_time_unit(1, :second, :native)`) |
  | `server.address` | llm_call start `server_address` |

  Gaps: Normandy has no `gen_ai.agent.id`, no `gen_ai.request.top_p` and the like, and
  never records message content (the opt-in content attributes are not supported).
  `approval_wait` has no standard attribute; export it as a custom attribute.

  ## Example bridge

  An illustrative sketch using `opentelemetry_telemetry`. It is not a dependency here, so
  this code is not compiled or run. It opens a span on `:start` and ends it on `:stop` or
  `:exception`:

      defmodule MyApp.NormandyOtel do
        require OpenTelemetry.Tracer, as: Tracer

        @spans [
          [:normandy, :agent, :run],
          [:normandy, :agent, :llm_call],
          [:normandy, :tool, :execute]
        ]

        def attach do
          events = for span <- @spans, suffix <- [:start, :stop, :exception], do: span ++ [suffix]
          :telemetry.attach_many("my-app-normandy-otel", events, &__MODULE__.handle/4, nil)
        end

        def handle([:normandy | rest] = event, _measurements, meta, _config) do
          {span, [phase]} = Enum.split(rest, -1)

          case phase do
            :start ->
              OpentelemetryTelemetry.start_telemetry_span(
                :my_app,
                span_name(span, meta),
                meta,
                %{kind: kind(span), attributes: attributes(span, meta)}
              )

            :stop ->
              OpentelemetryTelemetry.set_current_telemetry_span(:my_app, meta)
              Tracer.set_attributes(stop_attributes(meta))
              OpentelemetryTelemetry.end_telemetry_span(:my_app, meta)

            :exception ->
              OpentelemetryTelemetry.set_current_telemetry_span(:my_app, meta)
              Tracer.set_status(:error, inspect(meta[:reason]))
              OpentelemetryTelemetry.end_telemetry_span(:my_app, meta)
          end

          event
        end

        defp kind([:agent, :llm_call]), do: :client
        defp kind(_span), do: :internal

        defp span_name([:agent, :run], %{agent_name: name}) when is_binary(name),
          do: "invoke_agent " <> name

        defp span_name([:agent, :run], _meta), do: "invoke_agent"
        defp span_name([:agent, :llm_call], meta), do: "chat " <> to_string(meta[:model])
        defp span_name([:tool, :execute], meta), do: "execute_tool " <> to_string(meta[:tool_name])

        # gen_ai.operation.name and gen_ai.provider.name are required by the conventions.
        defp attributes(span, meta) do
          %{
            "gen_ai.operation.name" => operation(span),
            "gen_ai.provider.name" => provider(meta[:provider]),
            "gen_ai.request.model" => meta[:model],
            "gen_ai.agent.name" => meta[:agent_name],
            "gen_ai.conversation.id" => meta[:conversation_id]
          }
          |> reject_nil()
        end

        defp stop_attributes(meta) do
          %{
            "gen_ai.usage.input_tokens" => meta[:input_tokens],
            "gen_ai.usage.output_tokens" => meta[:output_tokens]
          }
          |> reject_nil()
        end

        defp operation([:agent, :run]), do: "invoke_agent"
        defp operation([:agent, :llm_call]), do: "chat"
        defp operation([:tool, :execute]), do: "execute_tool"

        defp provider(:anthropic), do: "anthropic"
        defp provider(nil), do: nil
        defp provider(other), do: to_string(other)

        defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
      end

  A real bridge must also handle a run `:exception` that has no matching `:start` (see
  "Killed runs"); `end_telemetry_span` will find no open span and report an error.

  ## Known limits

    * Killed runs: see "Killed runs". Inner spans of a killed run stay open.
    * Cross-process bridging: a process-keyed bridge ends a span only in the process that
      started it. Normandy carries the OTel context into the tasks it spawns (fan-out,
      `Turn.Server` tasks, `AgentProcess`), so parenting works across processes, but a
      span cannot be ended from another process.
    * Parked runs: a run waiting for approval is one open span that can last minutes.
      Use `approval_wait` and the approval span to tell wait from work. A server killed
      while parked emits no run `:exception`, so that span is never exported.
    * W3C propagation: `A2A.AgentTool` injects `traceparent` and `tracestate` into the
      A2A request, and `A2A.Server.handle_message/3` extracts them from the carrier it is
      given. The injection needs Claudio's A2A transport `:headers` option (Claudio 0.7.0).
      MCP calls carry no trace context: `Claudio.MCP.Client.call_tool/4` has no metadata
      or header field, so an MCP server's spans start a new trace.
    * Semantic conventions for GenAI are in Development status and may rename attributes.
  """
end
