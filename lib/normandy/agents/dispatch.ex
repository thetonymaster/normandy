defmodule Normandy.Agents.Dispatch do
  @moduledoc """
  The single chokepoint every agent tool call flows through.

  `dispatch_one/3` runs one tool call through a fixed pipeline:
  registry resolution → before-hooks → policy check → budget pre-check →
  execute → budget record → after-hooks. The behaviours are carried on a
  `Pipeline` struct so they can be injected in tests and replaced by real
  implementations in later phases. The default pipeline is allow-all / no-op /
  identity, preserving current behavior.

  The pipeline is also exposed as two composable halves: `classify/3` (registry →
  before-hooks → policy, producing a verdict with no side effects) and `execute/4`
  (budget → execute → record → after, running an already-classified call).
  `dispatch_one/3` is exactly `classify ➞ execute`; a durable shell consults
  `classify/3` to park a `:needs_approval` call before any side effect runs.
  """

  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Executor
  alias Normandy.Tools.Registry

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

  defmodule Pipeline do
    @moduledoc "Carries the behaviour functions the chokepoint consults."
    @type t :: %__MODULE__{
            before_hooks: [function()],
            policy_fn: function(),
            budget_check_fn: function(),
            budget_record_fn: function(),
            execute_fn: function(),
            after_hooks: [function()]
          }
    defstruct before_hooks: [],
              policy_fn: nil,
              budget_check_fn: nil,
              budget_record_fn: nil,
              execute_fn: nil,
              after_hooks: []
  end

  @doc """
  The default pipeline: allow-all policy, no-op budget, no hooks, bare executor.
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
      execute_fn: fn _config, tool, _name -> Executor.execute_tool(tool) end,
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
  Builds the tool struct from LLM-supplied input. Uses the tool's
  `prepare_input/2` if exported; otherwise maps known keys onto struct fields.
  """
  @spec prepare_tool(struct(), map()) :: struct()
  def prepare_tool(tool, input) when is_map(input) do
    if function_exported?(tool.__struct__, :prepare_input, 2) do
      tool.__struct__.prepare_input(tool, input)
    else
      struct(tool, atomize_known_keys(tool, input))
    end
  end

  @doc """
  Validates LLM-supplied input against a schema-based tool's schema BEFORE any
  side effect, so a malformed call is rejected at classify-time rather than
  blowing up inside (or three steps after) the tool's `execute/1`.

  Returns `:ok` when the input passes, or when the tool has no generated
  `validate/1` (plain-schema or hand-rolled tools — current behavior preserved);
  `{:error, errors}` with path-based validation errors otherwise.

  The LLM payload is string-keyed, but the schema validator looks up atom field
  names, so input is first mapped onto known field atoms using the same
  DoS-safe normalization `prepare_tool/2` uses (never `String.to_atom/1` on
  untrusted input). A tool that defines its own `prepare_input/2` owns its
  validation and is skipped here.
  """
  @spec validate_input(struct(), map()) :: :ok | {:error, list()}
  def validate_input(tool, input) when is_map(input) do
    mod = tool.__struct__

    cond do
      function_exported?(mod, :prepare_input, 2) ->
        :ok

      function_exported?(mod, :validate, 1) ->
        case mod.validate(atomize_known_keys(tool, input)) do
          {:ok, _validated} -> :ok
          {:error, errors} -> {:error, errors}
        end

      true ->
        :ok
    end
  end

  # Map LLM-supplied input (string- or atom-keyed) onto the tool's struct-field
  # atoms, dropping any key that isn't a real field. Shared by prepare_tool/2
  # (to build the struct) and validate_input/2 (to feed the atom-key-expecting
  # schema validator).
  defp atomize_known_keys(tool, input) do
    Enum.reduce(input, %{}, fn {key, value}, acc ->
      case normalize_tool_field_key(tool, key) do
        {:ok, atom_key} -> Map.put(acc, atom_key, value)
        :error -> acc
      end
    end)
  end

  @doc """
  Classifies one tool call: registry resolution → before-hooks → policy. Returns
  the routing decision WITHOUT executing the tool, so a durable shell can act on a
  `:needs_approval` verdict (park) before any side effect runs.

    * `{:execute, prepared, call}` — allowed; `prepared` is the built tool struct,
      `call` the post-before-hook `%ToolCall{}` (hooks may have rewritten it).
    * `{:deny, %ToolResult{}}` — registry miss, a before-hook `:halt`, or a policy
      `:deny`, already shaped into the error/denial result.
    * `{:needs_approval, prepared, call, info}` — policy wants human approval.
  """
  @spec classify(map(), ToolCall.t() | map(), Pipeline.t()) ::
          {:execute, struct(), ToolCall.t()}
          | {:deny, ToolResult.t()}
          | {:needs_approval, struct(), ToolCall.t(), map()}
  def classify(config, tool_call, pipeline \\ default_pipeline())

  def classify(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    call = %{call | input: normalize_tool_input(call.input)}

    case Registry.get(config.tool_registry, call.name) do
      {:ok, tool} ->
        case run_before_hooks(config, call, pipeline.before_hooks) do
          {:halt, %ToolResult{} = result} ->
            {:deny, result}

          {:cont, call} ->
            prepared = prepare_tool(tool, call.input)

            case validate_input(tool, call.input) do
              {:error, errors} ->
                {:deny, validation_error_result(call, errors)}

              :ok ->
                case apply_policy(pipeline, config, call, prepared) do
                  {:allow, _meta} -> {:execute, prepared, call}
                  {:deny, info} -> {:deny, denial_result(call, info, false)}
                  {:needs_approval, info} -> {:needs_approval, prepared, call, info}
                end
            end
        end

      :error ->
        {:deny, not_found_result(call)}
    end
  end

  def classify(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    classify(config, to_tool_call(raw_call), pipeline)
  end

  @doc """
  Executes a classified (`{:execute, prepared, call}`) tool call: budget pre-check →
  execute → budget record → after-hooks. Returns a `%ToolResult{}`. Skips
  re-classification — the verdict was already decided by `classify/3` (and, for an
  approved call, by a human), so re-running policy here would re-deny/re-park.
  """
  @spec execute(map(), struct(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
  def execute(config, prepared, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case pipeline.budget_check_fn.(config, call) do
      :ok ->
        result = execute_and_wrap(config, call, prepared, pipeline.execute_fn)
        pipeline.budget_record_fn.(config, call, result)
        run_after_hooks(config, call, result, pipeline.after_hooks)

      {:error, reason} ->
        budget_denial_result(call, reason)
    end
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
      {:execute, prepared, call} -> execute(config, prepared, call, pipeline)
      {:deny, %ToolResult{} = result} -> result
      {:needs_approval, _prepared, call, info} -> denial_result(call, info, true)
    end
  end

  def dispatch_one(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    dispatch_one(config, to_tool_call(raw_call), pipeline)
  end

  defp execute_and_wrap(config, call, prepared, execute_fn) do
    case execute_fn.(config, prepared, call.name) do
      {:ok, result} ->
        %ToolResult{tool_call_id: call.id, output: result, is_error: false}

      {:error, error} ->
        %ToolResult{tool_call_id: call.id, output: %{error: error}, is_error: true}
    end
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
  defp apply_policy(pipeline, config, call, prepared) do
    pipeline.policy_fn.(config, call, prepared)
  rescue
    e -> {:deny, %{reason: "policy check raised", rationale: Exception.message(e)}}
  catch
    kind, value -> {:deny, %{reason: "policy check failed (#{kind})", rationale: inspect(value)}}
  end

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
        error: "tool input failed schema validation",
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

  defp not_found_result(call) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{error: "Tool '#{call.name}' not found in registry"},
      is_error: true
    }
  end

  @doc false
  def normalize_tool_input(nil), do: %{}
  def normalize_tool_input(input) when is_map(input), do: input

  def normalize_tool_input(input) when is_binary(input) do
    case Poison.decode(input) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  def normalize_tool_input(_), do: %{}

  # Map an LLM-supplied input key (atom or binary) to a struct field atom on the
  # tool, returning :error for keys that don't correspond to any field. NEVER
  # calls String.to_atom/1 on untrusted input (atom-table exhaustion / DoS).
  @doc false
  def normalize_tool_field_key(tool, key) when is_atom(key) do
    if key != :__struct__ and Map.has_key?(tool, key), do: {:ok, key}, else: :error
  end

  def normalize_tool_field_key(tool, key) when is_binary(key) do
    Enum.find_value(Map.keys(tool), :error, fn field ->
      if is_atom(field) and field != :__struct__ and Atom.to_string(field) == key do
        {:ok, field}
      end
    end)
  end

  def normalize_tool_field_key(_tool, _key), do: :error
end
