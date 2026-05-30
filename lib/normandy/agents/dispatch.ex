defmodule Normandy.Agents.Dispatch do
  @moduledoc """
  The single chokepoint every agent tool call flows through.

  `dispatch_one/3` runs one tool call through a fixed pipeline:
  registry resolution → before-hooks → policy check → budget pre-check →
  execute → budget record → after-hooks. The behaviours are carried on a
  `Pipeline` struct so they can be injected in tests and replaced by real
  implementations in later phases. The default pipeline is allow-all / no-op /
  identity, preserving current behavior.
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
      input_with_atom_keys =
        Enum.reduce(input, %{}, fn {key, value}, acc ->
          case normalize_tool_field_key(tool, key) do
            {:ok, atom_key} -> Map.put(acc, atom_key, value)
            :error -> acc
          end
        end)

      struct(tool, input_with_atom_keys)
    end
  end

  @doc """
  Runs one tool call through the chokepoint pipeline and returns a %ToolResult{}.

  Accepts either a %ToolCall{} (non-streaming) or a raw string-keyed map
  (streaming); the latter is normalized first.
  """
  @spec dispatch_one(map(), ToolCall.t() | map(), Pipeline.t()) :: ToolResult.t()
  def dispatch_one(config, tool_call, pipeline \\ default_pipeline())

  def dispatch_one(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    call = %{call | input: normalize_tool_input(call.input)}

    case Registry.get(config.tool_registry, call.name) do
      {:ok, tool} ->
        with {:cont, call} <- run_before_hooks(config, call, pipeline.before_hooks),
             prepared = prepare_tool(tool, call.input),
             {:allow, _meta} <- pipeline.policy_fn.(config, call, prepared),
             :ok <- pipeline.budget_check_fn.(config, call) do
          result = execute_and_wrap(config, call, prepared, pipeline.execute_fn)
          pipeline.budget_record_fn.(config, call, result)
          run_after_hooks(config, call, result, pipeline.after_hooks)
        else
          {:halt, %ToolResult{} = result} -> result
          {:deny, info} -> denial_result(call, info, false)
          {:needs_approval, info} -> denial_result(call, info, true)
          {:error, reason} -> budget_denial_result(call, reason)
        end

      :error ->
        not_found_result(call)
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
