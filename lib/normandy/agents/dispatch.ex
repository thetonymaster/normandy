defmodule Normandy.Agents.Dispatch do
  @moduledoc """
  The single chokepoint every agent tool call flows through.

  `dispatch_one/3` runs one tool call through a fixed pipeline:
  toolset lookup → before-hooks → input validation → policy check → budget pre-check →
  execute → budget record → after-hooks. The behaviours are carried on a
  `Pipeline` struct so they can be injected in tests and replaced by real
  implementations in later phases. The default pipeline is allow-all / no-op /
  identity, preserving current behavior.

  The pipeline is also exposed as two composable halves: `classify/3` (toolset lookup →
  before-hooks → input validation → policy, producing a verdict with no side effects) and
  `execute/4` (budget → execute → record → after, running an already-classified call).
  `dispatch_one/3` is exactly `classify ➞ execute`; a durable shell consults
  `classify/3` to park a `:needs_approval` call before any side effect runs, and runs an
  approved one with `execute_approved/3`.

  ## Input

  The model's input is validated against the tool's input schema
  (`Normandy.Tools.Input.validate/2`) after the before-hooks, so a hook's rewrite is what is
  checked. The validated input travels in an `Invocation` beside the registered tool, and
  reaches the tool as `context.input`; the tool struct is never changed. Invalid input (an
  unknown key, a missing required key, a wrong type) answers the call with an `is_error`
  result naming the keys, and the turn goes on.

  ## Results the model sees

  A call answered without running its tool as asked gets `is_error: true` and an
  `output` of `%{error: message}` plus only the keys that apply (never a `null`). The
  message says what happened and what to do next. Keys: `denied: true` (a policy deny,
  the synchronous `:needs_approval` collapse, a budget refusal, a before-hook halt, a
  rejected or expired approval), `rule_id` and `rationale` (a policy's, when set),
  `validation_errors` (input that failed the tool's schema: a fixable mistake, so not
  `denied`), `expired: true` and `interrupted: true`. A tool's own `{:error, binary}`,
  or a raised exception, reaches the model as that text alone; any other error term as
  `%{error: term}`.

  ## Telemetry

  A call answered without running its tool emits `[:normandy, :tool, :denied]`
  (`%{count: 1}`, metadata from `Normandy.Telemetry.Metadata.tool_denied/4`) with
  `reason` `:policy` (a policy deny, or a `:needs_approval` verdict collapsed by
  `dispatch_one/3`), `:hook_halt` (a before-hook halted it) or `:budget` (the
  budget pre-check refused it). Approval outcomes (`:approval_rejected`,
  `:approval_expired`) are emitted by `Turn.Server`, the only shell that parks.
  Toolset misses and invalid or schema-failing input are errors, not denials,
  and emit nothing. A result cut by the cap (below) emits
  `[:normandy, :tool, :result_truncated]` (`%{original_chars, kept_chars}`, metadata from
  `Normandy.Telemetry.Metadata.tool_result_truncated/3`).

  ## Result cap

  Every result leaves the chokepoint through `finish/3`, after the `after_tool` slot and
  the after-hooks (which see the whole output): an output JSON cannot express, or a
  binary that is not valid UTF-8, becomes an error result; then a result whose text (what
  the model reads: a binary as-is, a number as its digits, anything else as JSON) is
  longer than the limit is cut to the limit, in characters (graphemes, so a
  multi-codepoint character is never split), and ends with
  `"\n[truncated: <kept> of <total> chars shown]"`. Error results are capped too. The
  limit is the tool's `Normandy.Tools.Toolset.register/3` `:max_result_chars` when it was
  registered with one (`nil` there turns the cap off for that tool), else the agent's
  `:max_tool_result_chars` (default 100_000; `nil` = no cap). A map or list output is cut
  as its JSON text, so the model gets a string.

  ## `after_tool`

  `Pipeline.after_tool` (`fn config, call, result -> result end`, default `nil`) runs on
  every result the chokepoint returns: executed, budget-denied, every `classify/3` denial
  (toolset miss, invalid or schema-failing input, a before-hook halt, a policy deny) and
  `dispatch_one/3`'s interim approval denial. It runs before the function `after_hooks`,
  which see only results of tools that ran, and the result answers the call's id
  whatever it returns. `Normandy.Behaviours.Config.to_pipeline/1` sets it from the agent's
  hook modules. For a denial it receives the call as the model sent it (input
  normalized); for an executed result, the call the before-hooks produced.

  ## `policy_fn` and `execute_fn`

  `policy_fn` is called as `(config, tool_call, invocation)`. `execute_fn` is called as
  `(config, invocation, tool_name)` when it has arity 3, or
  `(config, invocation, tool_name, tool_call)` when it has arity 4; `executor_opts/3` builds
  the `Normandy.Tools.Executor` options (context with the input, registration timeout) from
  them.
  """

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Telemetry.Metadata
  alias Normandy.Tools.Context
  alias Normandy.Tools.Executor
  alias Normandy.Tools.Input
  alias Normandy.Tools.Toolset

  defmodule Invocation do
    @moduledoc """
    A tool call ready to run: the tool as registered (never changed by the call), the
    model's input validated against the tool's input schema, and the call's timeout (the
    tool's registration `:timeout`, else `Normandy.Tools.Executor.default_timeout/0`).
    """
    @enforce_keys [:tool, :input, :timeout]
    defstruct [:tool, :input, :timeout]

    @type t :: %__MODULE__{tool: struct(), input: struct() | map(), timeout: pos_integer()}
  end

  defmodule Pipeline do
    @moduledoc "Carries the behaviour functions the chokepoint consults."
    @type t :: %__MODULE__{
            before_hooks: [function()],
            policy_fn: function(),
            budget_check_fn: function(),
            budget_record_fn: function(),
            execute_fn:
              (map(), Normandy.Agents.Dispatch.Invocation.t(), String.t() ->
                 Executor.execution_result())
              | (map(), Normandy.Agents.Dispatch.Invocation.t(), String.t(), ToolCall.t() ->
                   Executor.execution_result()),
            after_hooks: [function()],
            after_tool: (map(), ToolCall.t(), ToolResult.t() -> ToolResult.t()) | nil
          }
    defstruct before_hooks: [],
              policy_fn: nil,
              budget_check_fn: nil,
              budget_record_fn: nil,
              execute_fn: nil,
              after_hooks: [],
              after_tool: nil
  end

  @doc """
  The default pipeline: allow-all policy, no-op budget, no hooks, the bare executor, passing
  the call's `%Normandy.Tools.Context{}` (with the validated input) and timeout.
  Reproduces current behavior. Callers (e.g. BaseAgent) override `execute_fn`
  to add telemetry, and later phases override the behaviour functions.
  """
  @spec default_pipeline() :: Pipeline.t()
  def default_pipeline do
    %Pipeline{
      before_hooks: [],
      policy_fn: fn _config, _call, _invocation -> {:allow, %{}} end,
      budget_check_fn: fn _config, _call -> :ok end,
      budget_record_fn: fn _config, _call, _result -> :ok end,
      execute_fn: fn config, invocation, _name, call ->
        Executor.execute_tool(invocation.tool, executor_opts(config, invocation, call))
      end,
      after_hooks: []
    }
  end

  @doc "Normalizes a raw LLM tool call (struct or string-keyed map) into a %ToolCall{}."
  @spec to_tool_call(ToolCall.t() | map()) :: ToolCall.t()
  def to_tool_call(%ToolCall{} = call), do: %{call | input: normalize_tool_input(call.input)}

  def to_tool_call(%{} = raw) do
    %ToolCall{
      id: raw["id"] || raw[:id],
      name: raw["name"] || raw[:name],
      input: normalize_tool_input(raw["input"] || raw[:input])
    }
  end

  @doc """
  The `Normandy.Tools.Executor` options for `invocation`: the call's
  `%Normandy.Tools.Context{}` carrying the validated input, and the invocation's timeout.
  """
  @spec executor_opts(map(), Invocation.t(), ToolCall.t()) :: keyword()
  def executor_opts(config, %Invocation{} = invocation, %ToolCall{} = call),
    do: [context: Context.build(config, call, invocation.input), timeout: invocation.timeout]

  @doc """
  Classifies one tool call: toolset lookup → before-hooks → input validation → policy. Returns
  the routing decision WITHOUT executing the tool, so a durable shell can act on a
  `:needs_approval` verdict (park) before any side effect runs. Its only side
  effects are the `[:normandy, :tool, :denied]` event for a policy deny or hook halt and,
  for a `:deny` result, the pipeline's `after_tool` slot (every result the model sees
  passes it once; an `:execute` or `:needs_approval` verdict has no result yet).

    * `{:execute, %Invocation{}, call}` — allowed; `call` is the post-before-hook
      `%ToolCall{}` (hooks may have rewritten it).
    * `{:deny, %ToolResult{}}` — a toolset miss, input that is not an object or fails
      validation, a before-hook `:halt`, or a policy `:deny`, already shaped into the
      error/denial result.
    * `{:needs_approval, %Invocation{}, call, info}` — policy wants human approval.
  """
  @spec classify(map(), ToolCall.t() | map(), Pipeline.t()) ::
          {:execute, Invocation.t(), ToolCall.t()}
          | {:deny, ToolResult.t()}
          | {:needs_approval, Invocation.t(), ToolCall.t(), map()}
  def classify(config, tool_call, pipeline \\ default_pipeline())

  def classify(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    call = %{call | input: normalize_tool_input(call.input)}

    case route(config, call, pipeline) do
      {:deny, %ToolResult{} = result} -> {:deny, answer(config, call, result, pipeline)}
      verdict -> verdict
    end
  end

  def classify(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    classify(config, to_tool_call(raw_call), pipeline)
  end

  defp route(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case fetch_tool(config, call.name) do
      {:ok, _tool} when not is_map(call.input) ->
        {:deny, invalid_input_result(call)}

      {:ok, tool} ->
        # A hook may change a call's input, not which call it is: the result must
        # answer the model's tool_use id, and both shells order results by it.
        case run_before_hooks(config, call, pipeline.before_hooks) do
          {:halt, %ToolResult{} = result} ->
            emit_denied(config, call, :hook_halt)
            {:deny, %{result | tool_call_id: call.id}}

          {:cont, hooked} ->
            validate_and_decide(pipeline, config, tool, %{hooked | id: call.id})
        end

      :error ->
        {:deny, not_found_result(config, call)}
    end
  end

  defp validate_and_decide(pipeline, config, tool, call) do
    with {:ok, invocation} <- invocation(config, tool, call),
         do: decide(pipeline, config, call, invocation)
  end

  defp decide(pipeline, config, call, invocation) do
    case apply_policy(pipeline, config, call, invocation) do
      {:allow, _meta} -> {:execute, invocation, call}
      {:deny, info} -> {:deny, policy_denial(config, call, info, :deny)}
      {:needs_approval, info} -> {:needs_approval, invocation, call, info}
    end
  end

  defp fetch_tool(%{toolset: %Toolset{} = toolset}, name), do: Toolset.fetch(toolset, name)
  defp fetch_tool(_config, _name), do: :error

  # The validated input and the registration timeout, beside the tool as registered.
  defp invocation(config, tool, %ToolCall{} = call) do
    case Input.validate(tool, call.input) do
      {:ok, input} ->
        {:ok, %Invocation{tool: tool, input: input, timeout: timeout(config, call.name)}}

      {:error, errors} ->
        {:deny, validation_error_result(call, errors)}
    end
  end

  defp timeout(%{toolset: toolset}, name) do
    case Toolset.timeout(toolset, name) do
      nil -> Executor.default_timeout()
      timeout -> timeout
    end
  end

  # Every result the model will see passes the after_tool slot once; the result answers
  # the call's id whatever the slot returns.
  defp after_tool_slot(_config, _call, result, %Pipeline{after_tool: nil}), do: result

  defp after_tool_slot(config, call, result, %Pipeline{after_tool: after_tool}),
    do: %{after_tool.(config, call, result) | tool_call_id: call.id}

  # A result that leaves Dispatch with no after-hooks to run: the slot, then finish/3.
  defp answer(config, call, result, pipeline),
    do: finish(config, call, after_tool_slot(config, call, result, pipeline))

  @doc false
  # The last step of every result that leaves Dispatch, and of the results
  # Normandy.Hooks.ServerGlue rewrites through after_tool (interrupted, rejected and
  # expired results, which skip Dispatch): encodable/2, then the cap (see the
  # moduledoc's "Result cap"). Runs once per result: the cap's note is not idempotent.
  @spec finish(map(), ToolCall.t(), ToolResult.t()) :: ToolResult.t()
  def finish(config, %ToolCall{} = call, %ToolResult{} = result),
    do: finish(config, call, result, nil)

  defp finish(config, call, result, rendering) do
    {result, {_output, text}} = encodable(result, rendering)
    cap(result, text, config, call)
  end

  # A rendering is {output, text}: the output a result held when ToolResult.render/1
  # turned it into text, so later steps reuse the text while the result still holds that
  # output (=== on the same term returns at once) and render again only when a hook
  # replaced it. nil when nothing was rendered yet.
  #
  # Hooks (before-hook halts, after_tool, after_hooks) may build any %ToolResult{},
  # and memory keeps it for every later request. So the encodability check runs on
  # the final result, the last point before it can reach memory. Returns the result,
  # replaced by an error result when the model could not read it, and its rendering.
  defp encodable(%ToolResult{output: output} = result, {rendered, _text} = rendering)
       when output === rendered,
       do: {result, rendering}

  defp encodable(%ToolResult{output: output} = result, _stale_or_nil) do
    case ToolResult.render(output) do
      {:ok, text} when is_binary(output) ->
        if String.valid?(text),
          do: {result, {output, text}},
          else: unreadable(result, invalid_utf8_output())

      {:ok, text} ->
        {result, {output, text}}

      {:error, exception} ->
        unreadable(result, unencodable_output(exception))
    end
  end

  defp unreadable(result, message),
    do: {%{result | output: message, is_error: true}, {message, message}}

  @doc """
  Executes a classified (`{:execute, invocation, call}`) tool call: budget pre-check →
  execute → budget record → `after_tool` slot → after-hooks. A budget denial passes
  `after_tool` too. Returns a `%ToolResult{}`. Skips
  re-classification — the verdict was already decided by `classify/3` (and, for an
  approved call, by a human), so re-running policy here would re-deny/re-park.
  """
  @spec execute(map(), Invocation.t(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
  def execute(config, %Invocation{} = invocation, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case pipeline.budget_check_fn.(config, call) do
      :ok ->
        {result, rendering} = execute_and_wrap(config, call, invocation, pipeline.execute_fn)
        pipeline.budget_record_fn.(config, call, result)

        {result, rendering} =
          config |> after_tool_slot(call, result, pipeline) |> encodable(rendering)

        config
        |> run_after_hooks(call, result, pipeline.after_hooks)
        |> Map.put(:tool_call_id, call.id)
        |> then(&finish(config, call, &1, rendering))

      {:error, reason} ->
        emit_denied(config, call, :budget)
        answer(config, call, budget_denial_result(call, reason), pipeline)
    end
  end

  @doc """
  Executes a call a human approved (a `:needs_approval` verdict a durable shell parked):
  looks the tool up again and validates the parked call's input again (both are
  deterministic), then runs `execute/4`. Policy is not consulted again: it would park the
  call again. A tool no longer registered, or input that no longer validates, answers the
  call with the same result `classify/3` would give, through the `after_tool` slot.

  The approval covers the call's name and input, not the tool's code: after a redeploy, or
  a supplement that registers another tool under that name, the approved call runs
  whatever tool now holds the name. To bind an approval to one implementation, version
  the tool's name (`"refund_v2"`) when its behaviour changes.
  """
  @spec execute_approved(map(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
  def execute_approved(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    with {:ok, tool} <- fetch_tool(config, call.name),
         {:ok, invocation} <- invocation(config, tool, call) do
      execute(config, invocation, call, pipeline)
    else
      :error -> answer(config, call, not_found_result(config, call), pipeline)
      {:deny, %ToolResult{} = result} -> answer(config, call, result, pipeline)
    end
  end

  @doc """
  Emits `[:normandy, :tool, :denied]` for `call`, answered without running its
  tool. Shells that answer a call outside the pipeline (`Turn.Server` approval
  rejection or expiry) call this too, so every denial has one shape.
  """
  @spec emit_denied(map(), ToolCall.t(), atom(), String.t() | nil) :: :ok
  def emit_denied(config, %ToolCall{} = call, reason, rule_id \\ nil) do
    :telemetry.execute(
      [:normandy, :tool, :denied],
      %{count: 1},
      Metadata.tool_denied(config, call, reason, rule_id)
    )
  end

  @doc """
  Runs one tool call through the chokepoint pipeline and returns a %ToolResult{}.

  Re-expressed as `classify ➞ execute`; observable behavior is unchanged. Accepts
  either a %ToolCall{} (non-streaming) or a raw string-keyed map (streaming); the
  latter is normalized first. A `:needs_approval` verdict collapses to the interim
  denial result here (the synchronous path cannot wait for a human); only the
  durable shell parks on it.
  """
  @spec dispatch_one(map(), ToolCall.t() | map(), Pipeline.t()) :: ToolResult.t()
  def dispatch_one(config, tool_call, pipeline \\ default_pipeline())

  def dispatch_one(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case classify(config, call, pipeline) do
      {:execute, invocation, call} ->
        execute(config, invocation, call, pipeline)

      {:deny, %ToolResult{} = result} ->
        result

      {:needs_approval, _invocation, call, info} ->
        answer(config, call, policy_denial(config, call, info, :needs_approval), pipeline)
    end
  end

  def dispatch_one(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    dispatch_one(config, to_tool_call(raw_call), pipeline)
  end

  defp execute_and_wrap(config, call, invocation, execute_fn) do
    case call_execute_fn(execute_fn, config, invocation, call) do
      {:ok, result} -> wrap_output(call, result)
      {:error, error} -> wrap_error(call, error)
    end
  end

  # The model reads a tool result as JSON (ToolResult's BaseIOSchema impl), and
  # memory keeps the result for every later request. So an output JSON cannot
  # express (a tuple, a pid) is replaced here by an error result that says so,
  # before it reaches memory. Returns the result and its rendering (encodable/2); a
  # binary is checked after the after_tool slot, which may still replace it.
  defp wrap_output(call, output) when is_binary(output) or is_number(output),
    do: {%ToolResult{tool_call_id: call.id, output: output, is_error: false}, nil}

  defp wrap_output(call, output),
    do: encodable(%ToolResult{tool_call_id: call.id, output: output, is_error: false}, nil)

  # An error reason is a message for the model. A binary is sent as it is (AX-15: the
  # memory tool's reference strings, an Executor timeout), with is_error carrying the
  # flag; an exception as its message (encoding it would send its fields and
  # "__exception__"). Any other term keeps the %{error: term} shape, as its inspect/1
  # text when JSON cannot express it (a tuple such as {:http, 500}).
  defp wrap_error(call, error) when is_binary(error),
    do: {%ToolResult{tool_call_id: call.id, output: error, is_error: true}, nil}

  defp wrap_error(call, error) when is_exception(error),
    do:
      {%ToolResult{tool_call_id: call.id, output: Exception.message(error), is_error: true}, nil}

  defp wrap_error(call, error) do
    output = %{error: error}

    case ToolResult.render(output) do
      {:ok, text} ->
        {%ToolResult{tool_call_id: call.id, output: output, is_error: true}, {output, text}}

      {:error, _exception} ->
        {%ToolResult{tool_call_id: call.id, output: %{error: inspect(error)}, is_error: true},
         nil}
    end
  end

  # Sent bare, like a tool's own {:error, binary} (AX-15).
  defp invalid_utf8_output, do: "the tool ran, but its output is not valid UTF-8 text"

  # The tool's registration :max_result_chars wins over the agent's
  # :max_tool_result_chars, including a registered nil. Dispatch's callers pass partial
  # configs (bare maps in tests), so a config without the key has the default cap.
  # text is the result's rendering (encodable/2), what the model reads.
  defp cap(result, text, config, call) do
    case result_limit(config, call.name) do
      {nil, _source} -> result
      {limit, source} -> cap_text(result, text, %{limit: limit, source: source}, config, call)
    end
  end

  defp result_limit(config, name) do
    case tool_limit(config, name) do
      {:ok, limit} ->
        {limit, :tool}

      :error ->
        default = BaseAgentConfig.default_max_tool_result_chars()
        {Map.get(config, :max_tool_result_chars, default), :agent}
    end
  end

  defp tool_limit(%{toolset: %Toolset{} = toolset}, name),
    do: Toolset.max_result_chars(toolset, name)

  defp tool_limit(_config, _name), do: :error

  # A text's byte size bounds its grapheme count, so a short text skips the walk.
  defp cap_text(result, text, %{limit: limit}, _config, _call) when byte_size(text) <= limit,
    do: result

  defp cap_text(result, text, %{limit: limit, source: source}, config, call) do
    case String.length(text) do
      total when total <= limit ->
        result

      total ->
        :telemetry.execute(
          [:normandy, :tool, :result_truncated],
          %{original_chars: total, kept_chars: limit},
          Metadata.tool_result_truncated(config, call, source)
        )

        kept = String.slice(text, 0, limit)
        %{result | output: kept <> "\n[truncated: #{limit} of #{total} chars shown]"}
    end
  end

  # Sent bare, like invalid_utf8_output/0 and a tool's own {:error, binary} (AX-15).
  defp unencodable_output(exception),
    do: "the tool ran, but its output cannot be sent as JSON: #{unencodable(exception)}"

  defp unencodable(%Protocol.UndefinedError{value: value}),
    do: "it contains #{Describe.type_of(value)}"

  # By the exception's module only: a message (Jason.EncodeError's "invalid byte ... in
  # <<...>>") can quote the output's bytes into the model's text.
  defp unencodable(%module{}), do: "encoding it raised #{inspect(module)}"

  defp call_execute_fn(execute_fn, config, invocation, call) when is_function(execute_fn, 4),
    do: execute_fn.(config, invocation, call.name, call)

  defp call_execute_fn(execute_fn, config, invocation, call),
    do: execute_fn.(config, invocation, call.name)

  defp policy_denial(config, call, info, verdict) do
    emit_denied(config, call, :policy, Map.get(info, :rule_id))
    denial_result(call, info, verdict)
  end

  defp run_before_hooks(_config, call, []), do: {:cont, call}

  defp run_before_hooks(config, call, [hook | rest]) do
    case hook.(config, call) do
      {:cont, %ToolCall{} = call} -> run_before_hooks(config, call, rest)
      {:halt, %ToolResult{} = result} -> {:halt, result}
    end
  end

  # Belt-and-suspenders fail-closed at the chokepoint. The policy_fn (Phase 2's
  # pipeline) owns the fail-closed contract, but a buggy or network-backed policy
  # engine that raises, or that times out / is unreachable (surfacing as an exit),
  # must never let a tool call slip through un-vetted. Any escape is normalized to
  # {:deny, …}, honoring the spec's "a policy timeout/unreachable surfaces as
  # {:deny, …}". `catch` covers exits/throws (e.g. a GenServer.call timeout);
  # `rescue` covers raised exceptions.
  #
  # The rationale goes to the model, and a policy engine's exception or exit can
  # carry its ctx (config and client), so it names the failure's shape only.
  defp apply_policy(pipeline, config, call, invocation) do
    pipeline.policy_fn.(config, call, invocation)
  rescue
    e -> {:deny, %{reason: "policy check raised", rationale: inspect(e.__struct__)}}
  catch
    kind, value ->
      {:deny, %{reason: "policy check failed (#{kind})", rationale: describe_failure(value)}}
  end

  defp describe_failure(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do: "{#{inspect(elem(tuple, 0))}, ...}"

  defp describe_failure(value), do: Describe.type_of(value)

  defp run_after_hooks(_config, _call, result, []), do: result

  defp run_after_hooks(config, call, result, [hook | rest]) do
    run_after_hooks(config, call, hook.(config, call, result), rest)
  end

  @doc false
  # The one shape of a result answering a call Normandy did not run as asked (Dispatch's
  # denials and errors, Turn's rejection and expiry, Turn.Server's interrupted result,
  # Hooks.Runner's halts): `%{error: message}` plus every extra key whose value is not
  # nil, with is_error set. A nil is never sent as a JSON null.
  @spec error_result(String.t() | nil, String.t(), map()) :: ToolResult.t()
  def error_result(call_id, message, extra \\ %{}) when is_binary(message) and is_map(extra) do
    output =
      for {key, value} <- extra, not is_nil(value), into: %{error: message}, do: {key, value}

    %ToolResult{tool_call_id: call_id, output: output, is_error: true}
  end

  defp denial_result(call, info, :deny) do
    message =
      case Map.get(info, :reason) do
        reason when is_binary(reason) and reason != "" ->
          "This call was blocked by policy (#{reason}). " <>
            "Do not retry it; continue without it or tell the user."

        _none ->
          "This call was blocked by policy. Do not retry it; continue without it or tell the user."
      end

    error_result(call.id, message, policy_keys(info))
  end

  defp denial_result(call, info, :needs_approval) do
    error_result(
      call.id,
      "This action needs human approval, which is not available in this run. " <>
        "Do not retry it; tell the user it requires approval.",
      policy_keys(info)
    )
  end

  defp policy_keys(info),
    do: %{rule_id: Map.get(info, :rule_id), rationale: Map.get(info, :rationale), denied: true}

  defp validation_error_result(call, errors) do
    error_result(
      call.id,
      "invalid input for #{call.name}: #{Input.message(errors)}; the tool was not run. " <>
        "Correct the input and call the tool again.",
      %{validation_errors: errors}
    )
  end

  # The budget tracker's reason is shown only when it is text; any other term is the
  # tracker's own data, not a message for the model.
  defp budget_denial_result(call, reason) do
    detail = if is_binary(reason) and reason != "", do: " (#{reason})", else: ""

    error_result(
      call.id,
      "The tool budget is used up#{detail}; the tool was not run. Answer with what you have.",
      %{denied: true}
    )
  end

  defp invalid_input_result(call) do
    error_result(
      call.id,
      "tool input is not a JSON object (it may have been cut off); the tool was not run. " <>
        "Send the arguments as a JSON object."
    )
  end

  @max_listed_tools 20

  defp not_found_result(config, call),
    do: error_result(call.id, "No tool named '#{call.name}'. #{available_tools(config)}")

  defp available_tools(%{toolset: %Toolset{} = toolset}) do
    case toolset |> Toolset.list_names() |> Enum.sort() do
      [] ->
        "This agent has no tools."

      names when length(names) > @max_listed_tools ->
        {listed, rest} = Enum.split(names, @max_listed_tools)
        "Available tools: #{Enum.join(listed, ", ")}, and #{length(rest)} more."

      names ->
        "Available tools: #{Enum.join(names, ", ")}."
    end
  end

  defp available_tools(_config), do: "This agent has no tools."

  # A JSON object string is decoded. Anything that is not an object (truncated
  # JSON, an array, a number) is kept as it came, so classify/3 can refuse the
  # call and tell the model, instead of running the tool with empty input.
  @doc false
  def normalize_tool_input(nil), do: %{}
  def normalize_tool_input(input) when is_map(input), do: input

  def normalize_tool_input(input) when is_binary(input) do
    case Normandy.JSON.decode(input) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> input
    end
  end

  def normalize_tool_input(input), do: input
end
