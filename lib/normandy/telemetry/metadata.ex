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
  """

  alias Normandy.Components.AgentMemory
  alias Normandy.Telemetry.Provider

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
