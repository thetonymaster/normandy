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
  def to_tool_call(%ToolCall{} = call), do: call

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
  def prepare_tool(tool, input) do
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
