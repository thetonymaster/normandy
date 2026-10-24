defmodule Normandy.Hooks.Context do
  @moduledoc """
  What a hook callback knows about the agent it runs for: the `event`, the agent's `name`
  (`agent_name`), `model` and `session_id`, the `turn_id`, and `values` (the agent's
  `tool_context`). It carries no config, memory or client, so a hook that logs it leaks
  nothing the agent was not told to share.

  `turn_id` is `nil` for `on_session_start`, `on_passivate` and `on_prompt` (the prompt is
  admitted before the turn starts), and for `on_turn_end` after a rejected input or a
  `BaseAgent` run that raised.
  """

  defstruct [:event, :agent_name, :model, :session_id, :turn_id, values: %{}]

  @type t :: %__MODULE__{
          event: atom() | nil,
          agent_name: String.t() | nil,
          model: String.t() | nil,
          session_id: String.t() | nil,
          turn_id: String.t() | nil,
          values: map()
        }

  @doc "Builds the context for `event` from `config`; `turn_id:` in `opts` overrides the memory's."
  @spec build(map(), atom(), keyword()) :: t()
  def build(config, event, opts \\ []) do
    %__MODULE__{
      event: event,
      agent_name: Map.get(config, :name),
      model: Map.get(config, :model),
      session_id: Map.get(config, :session_id),
      turn_id: Keyword.get_lazy(opts, :turn_id, fn -> memory_turn_id(config) end),
      values: Map.get(config, :tool_context) || %{}
    }
  end

  defp memory_turn_id(%{memory: %{current_turn_id: id}}), do: id
  defp memory_turn_id(_config), do: nil
end
