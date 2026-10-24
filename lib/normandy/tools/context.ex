defmodule Normandy.Tools.Context do
  @moduledoc """
  What a tool knows about the call it serves; the second argument of
  `c:Normandy.Tool.run/2`.

  Built per tool call by the dispatch pipeline from the agent config, the `%ToolCall{}` and
  the validated input. `input` is the model's input after `Normandy.Tools.Input.validate/2`:
  a struct of the tool's declared input schema, or a string-keyed map. `values` is the
  config's `tool_context`: plain data the application sets per session (for example
  `%{memory_namespace: "acme/user-42"}`). It is persisted in the session's config template,
  so it must hold no secrets; resolve secrets through `Normandy.Behaviours.CredentialProvider`,
  keyed by a value from here.

  The model sets only `input`, and only through validation; the tool struct and the rest of
  the context are out of its reach.
  """

  alias Normandy.Components.ToolCall

  @enforce_keys [:tool_call_id]
  defstruct [:session_id, :agent_name, :turn_id, :tool_call_id, input: nil, values: %{}]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          agent_name: String.t() | nil,
          turn_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          input: struct() | map() | nil,
          values: map()
        }

  @doc """
  Builds the context for `call` from `config` (a `%BaseAgentConfig{}` or a partial map) and
  the call's validated `input`.
  """
  @spec build(map(), ToolCall.t(), struct() | map()) :: t()
  def build(config, %ToolCall{} = call, input) do
    memory = Map.get(config, :memory)

    %__MODULE__{
      session_id: Map.get(config, :session_id),
      agent_name: Map.get(config, :name),
      turn_id: memory && Map.get(memory, :current_turn_id),
      tool_call_id: call.id,
      input: input,
      values: Map.get(config, :tool_context) || %{}
    }
  end
end
