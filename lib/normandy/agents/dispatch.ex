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

  ## Telemetry

  A call answered without running its tool emits `[:normandy, :tool, :denied]`
  (`%{count: 1}`, metadata from `Normandy.Telemetry.Metadata.tool_denied/4`) with
  `reason` `:policy` (a policy deny, or a `:needs_approval` verdict collapsed by
  `dispatch_one/3`), `:hook_halt` (a before-hook halted it) or `:budget` (the
  budget pre-check refused it). Approval outcomes (`:approval_rejected`,
  `:approval_expired`) are emitted by `Turn.Server`, the only shell that parks.
  Toolset misses and invalid or schema-failing input are errors, not denials,
  and emit nothing.

  ## `after_tool`

  `Pipeline.after_tool` (`fn config, call, result -> result end`, default `nil`) runs on
  every result the chokepoint returns: executed, budget-denied, every `classify/3` denial
  (registry miss, invalid or schema-failing input, a before-hook halt, a policy deny) and
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

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Telemetry.Metadata
  alias Normandy.Tools.Context
  alias Normandy.Tools.Executor
  alias Normandy.Tools.Input
  alias Normandy.Tools.Toolset

  defmodule DenialEnvelope do
    @moduledoc "Structured record of a denied (or approval-pending) tool call."
    @type t :: %__MODULE__{
            call_id: String.t() | nil,
            reason: String.t(),
            rule_id: String.t() | nil,
            rationale: String.t() | nil,
            pending_approval: boolean()
          }
    defstruct call_id: nil,
              reason: "denied",
              rule_id: nil,
              rationale: nil,
              pending_approval: false
  end

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
      policy_fn: fn _config, _call, _tool -> {:allow, %{}} end,
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
        {:deny, not_found_result(call)}
    end
  end

  defp validate_and_decide(pipeline, config, tool, call) do
    with {:ok, invocation} <- invocation(config, tool, call),
         do: decide(pipeline, config, call, invocation)
  end

  defp decide(pipeline, config, call, invocation) do
    case apply_policy(pipeline, config, call, invocation) do
      {:allow, _meta} -> {:execute, invocation, call}
      {:deny, info} -> {:deny, policy_denial(config, call, info, false)}
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
  defp answer(_config, _call, result, %Pipeline{after_tool: nil}), do: ensure_encodable(result)

  defp answer(config, call, result, %Pipeline{after_tool: after_tool}),
    do: ensure_encodable(%{after_tool.(config, call, result) | tool_call_id: call.id})

  # Hooks (before-hook halts, after_tool, after_hooks) may build any %ToolResult{},
  # and memory keeps it for every later request. So the encodability check runs on
  # the final result, the last point before it can reach memory.
  @doc false
  # Also called by Normandy.Hooks.ServerGlue on the results it rewrites through
  # after_tool (interrupted, rejected and expired results), which skip Dispatch.
  @spec ensure_encodable(ToolResult.t()) :: ToolResult.t()
  def ensure_encodable(%ToolResult{output: output} = result)
      when is_binary(output) or is_number(output),
      do: result

  def ensure_encodable(%ToolResult{output: output} = result) do
    case Normandy.JSON.encode(output) do
      {:ok, _json} -> result
      {:error, exception} -> %{result | output: unencodable_output(exception), is_error: true}
    end
  end

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
        result = execute_and_wrap(config, call, invocation, pipeline.execute_fn)
        pipeline.budget_record_fn.(config, call, result)
        result = answer(config, call, result, pipeline)

        config
        |> run_after_hooks(call, result, pipeline.after_hooks)
        |> Map.put(:tool_call_id, call.id)
        |> ensure_encodable()

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
  """
  @spec execute_approved(map(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
  def execute_approved(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    with {:ok, tool} <- fetch_tool(config, call.name),
         {:ok, invocation} <- invocation(config, tool, call) do
      execute(config, invocation, call, pipeline)
    else
      :error -> answer(config, call, not_found_result(call), pipeline)
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
        answer(config, call, policy_denial(config, call, info, true), pipeline)
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
  # before it reaches memory.
  defp wrap_output(call, output) when is_binary(output) or is_number(output),
    do: %ToolResult{tool_call_id: call.id, output: output, is_error: false}

  defp wrap_output(call, output) do
    case Normandy.JSON.encode(output) do
      {:ok, _json} ->
        %ToolResult{tool_call_id: call.id, output: output, is_error: false}

      {:error, exception} ->
        %ToolResult{
          tool_call_id: call.id,
          output: unencodable_output(exception),
          is_error: true
        }
    end
  end

  # An error reason is a message for the model: one JSON cannot express (a tuple
  # such as {:http, 500}) is sent as its inspect/1 text, the only form it has.
  defp wrap_error(call, error) do
    output =
      case Normandy.JSON.encode(%{error: error}) do
        {:ok, _json} -> %{error: error}
        {:error, _exception} -> %{error: inspect(error)}
      end

    %ToolResult{tool_call_id: call.id, output: output, is_error: true}
  end

  defp unencodable_output(exception),
    do: %{
      error: "the tool ran, but its output cannot be sent as JSON: #{unencodable(exception)}"
    }

  defp unencodable(%Protocol.UndefinedError{value: value}),
    do: "it contains #{Describe.type_of(value)}"

  defp unencodable(exception), do: Exception.message(exception)

  defp call_execute_fn(execute_fn, config, invocation, call) when is_function(execute_fn, 4),
    do: execute_fn.(config, invocation, call.name, call)

  defp call_execute_fn(execute_fn, config, invocation, call),
    do: execute_fn.(config, invocation, call.name)

  defp policy_denial(config, call, info, pending?) do
    emit_denied(config, call, :policy, Map.get(info, :rule_id))
    denial_result(call, info, pending?)
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

  defp denial_result(call, info, pending?) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{
        error: Map.get(info, :reason, "denied by policy"),
        rationale: Map.get(info, :rationale),
        rule_id: Map.get(info, :rule_id),
        denied: true,
        pending_approval: pending?
      },
      is_error: true
    }
  end

  defp validation_error_result(call, errors) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{
        error: "invalid input for #{call.name}: #{Input.message(errors)}; the tool was not run",
        validation_errors: errors,
        denied: true
      },
      is_error: true
    }
  end

  defp budget_denial_result(call, reason) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{error: "budget check failed: #{inspect(reason)}", denied: true},
      is_error: true
    }
  end

  defp invalid_input_result(call) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{
        error: "tool input is not a JSON object (it may have been cut off); the tool was not run",
        denied: true
      },
      is_error: true
    }
  end

  defp not_found_result(call) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{error: "Tool '#{call.name}' not found in registry"},
      is_error: true
    }
  end

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
