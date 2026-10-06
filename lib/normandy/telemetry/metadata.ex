defmodule Normandy.Telemetry.Metadata do
  @moduledoc """
  Builds the metadata maps shared by the `[:normandy, :agent, :run]`,
  `[:normandy, :agent, :llm_call]` and `[:normandy, :tool, :execute]` spans, so
  `BaseAgent` and `Turn.Server` (which hand-emits the run span) report the same keys.

  Keys with no value are left out. Metadata never carries message content.

    * `:model`, `:agent_name` - always present (as before), even when `nil`
    * `:provider` - `Normandy.Telemetry.Provider.provider/1`, omitted when unknown
    * `:session_id` - `config.session_id` (set by `Turn.Server`), omitted when nil
    * `:conversation_id` - the session id, when there is one
    * `:turn_id` - the memory turn id: `ids/1` reads it from the config's memory
      (the llm_call and tool spans run inside an admitted turn); `run/2` takes it
      from `:turn_id` because the run span starts before `BaseAgent` admits input

  Tool spans (`tool/3`) and `[:normandy, :tool, :denied]` (`tool_denied/4`) add the
  call's `:tool_name` and `:tool_call_id`; spans also add `:tool_description` and
  `:tool_type` (`:extension` for an MCP-wrapped tool, `:function` otherwise).
  """

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Telemetry.Provider
  alias Normandy.Tool

  @doc """
  Run span metadata. Options: `:turn_id` - the turn id, when already known.
  """
  @spec run(map(), keyword()) :: map()
  def run(config, opts \\ []) do
    optional =
      %{provider: Provider.provider(config.client), turn_id: Keyword.get(opts, :turn_id)}
      |> Map.merge(session_ids(config))
      |> reject_nil()

    Map.merge(%{model: config.model, agent_name: config.name}, optional)
  end

  @doc """
  The ids an llm_call or tool span carries: `:turn_id`, `:session_id` and
  `:conversation_id`, each only when present.
  """
  @spec ids(map()) :: map()
  def ids(config) do
    %{turn_id: turn_id(config)}
    |> Map.merge(session_ids(config))
    |> reject_nil()
  end

  @doc """
  `[:normandy, :tool, :execute]` span metadata for `call`, run by `tool` (the tool as
  registered). `:tool_name` and `:agent_name` are always present (as before);
  `:tool_call_id` and `:tool_description` only when known.
  """
  @spec tool(map(), ToolCall.t(), struct()) :: map()
  def tool(config, %ToolCall{} = call, tool) do
    optional =
      %{tool_call_id: call.id, tool_description: tool_description(tool)}
      |> Map.merge(ids(config))
      |> reject_nil()

    Map.merge(
      %{tool_name: call.name, agent_name: Map.get(config, :name), tool_type: tool_type(tool)},
      optional
    )
  end

  @doc """
  `[:normandy, :tool, :denied]` metadata: a call answered without running its
  tool. `reason` is one of `:policy | :budget | :hook_halt | :approval_expired |
  :approval_rejected`; `rule_id` is the policy rule, when one is known.
  """
  @spec tool_denied(map(), ToolCall.t(), atom(), String.t() | nil) :: map()
  def tool_denied(config, %ToolCall{} = call, reason, rule_id) do
    optional =
      %{tool_call_id: call.id, rule_id: rule_id}
      |> Map.merge(ids(config))
      |> reject_nil()

    Map.merge(
      %{tool_name: call.name, reason: reason, agent_name: Map.get(config, :name)},
      optional
    )
  end

  @doc """
  `[:normandy, :tool, :result_truncated]` metadata: a tool result cut to its cap.
  `limit_source` is `:tool` (the tool's `Toolset.register/3` `:max_result_chars`) or
  `:agent` (the agent's `:max_tool_result_chars`).
  """
  @spec tool_result_truncated(map(), ToolCall.t(), :agent | :tool) :: map()
  def tool_result_truncated(config, %ToolCall{} = call, limit_source) do
    optional =
      %{tool_call_id: call.id}
      |> Map.merge(ids(config))
      |> reject_nil()

    Map.merge(
      %{tool_name: call.name, agent_name: Map.get(config, :name), limit_source: limit_source},
      optional
    )
  end

  defp tool_type(%ToolWrapper{}), do: :extension
  defp tool_type(_tool), do: :function

  # Runs before the tool, outside the Executor's protection, so it must never
  # fail the call: a raising description/1 just leaves the key out.
  defp tool_description(tool) do
    Tool.description(tool)
  rescue
    _ -> nil
  catch
    _kind, _value -> nil
  end

  @doc "The memory's current turn id, or `nil`."
  @spec turn_id(map()) :: String.t() | nil
  def turn_id(%{memory: %AgentMemory{} = memory}), do: AgentMemory.get_current_turn_id(memory)
  def turn_id(_config), do: nil

  defp session_ids(config) do
    case Map.get(config, :session_id) do
      nil -> %{}
      session_id -> %{session_id: session_id, conversation_id: session_id}
    end
  end

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
