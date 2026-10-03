defmodule Normandy.Tools.Context do
  @moduledoc """
  What a `Normandy.Tools.ContextualTool` knows about the call it serves.

  Built per tool call by the dispatch pipeline (`build/2`) from the agent config and the
  `%ToolCall{}`. `values` is the config's `tool_context`: plain data the application sets
  per session (for example `%{memory_namespace: "acme/user-42"}`). It is persisted in the
  session's config template, so it must hold no secrets; resolve secrets through
  `Normandy.Behaviours.CredentialProvider`, keyed by a value from here.

  The model never sees or sets any of this: the context lives outside the tool struct.
  """

  alias Normandy.Components.ToolCall

  @enforce_keys [:tool_call_id]
  defstruct [:session_id, :agent_name, :turn_id, :tool_call_id, values: %{}]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          agent_name: String.t() | nil,
          turn_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          values: map()
        }

  @doc "Builds the context for `call` from `config` (a `%BaseAgentConfig{}` or a partial map)."
  @spec build(map(), ToolCall.t()) :: t()
  def build(config, %ToolCall{} = call) do
    memory = Map.get(config, :memory)

    %__MODULE__{
      session_id: Map.get(config, :session_id),
      agent_name: Map.get(config, :name),
      turn_id: memory && Map.get(memory, :current_turn_id),
      tool_call_id: call.id,
      values: Map.get(config, :tool_context) || %{}
    }
  end
end
