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
  alias Normandy.Tools.BaseTool

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
  `[:normandy, :tool, :execute]` span metadata for `call`, run as the built tool
  `prepared`. `:tool_name` and `:agent_name` are always present (as before);
  `:tool_call_id` and `:tool_description` only when known.
  """
  @spec tool(map(), ToolCall.t(), struct()) :: map()
  def tool(config, %ToolCall{} = call, prepared) do
    optional =
      %{tool_call_id: call.id, tool_description: tool_description(prepared)}
      |> Map.merge(ids(config))
      |> reject_nil()

    Map.merge(
      %{tool_name: call.name, agent_name: Map.get(config, :name), tool_type: tool_type(prepared)},
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

  defp tool_type(%ToolWrapper{}), do: :extension
  defp tool_type(_tool), do: :function

  defp tool_description(tool) do
    case BaseTool.impl_for(tool) do
      nil ->
        nil

      impl ->
        if function_exported?(impl, :tool_description, 1),
          do: BaseTool.tool_description(tool),
          else: nil
    end
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
