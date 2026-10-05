defmodule Normandy.LLM.Request do
  @moduledoc """
  One call to a model: what `Normandy.Agents.Model.converse/3` and
  `Normandy.Agents.Model.stream/3` receive.

  - `:model` - the model id
  - `:system` - the system prompt, or `nil`. `:messages` never holds a `"system"` message.
  - `:messages` - the conversation, oldest first, as `Normandy.Components.Message` structs
  - `:response_model` - an empty struct of the shape the caller expects back (see
    "Response content" in `Normandy.Agents.Model`), or `nil` for the answer as text
  - `:temperature` - `nil` leaves it unset (Opus 4.7+ reject sampling parameters)
  - `:max_tokens` - required by the Messages API
  - `:tools` - tool schemas, `%{name:, description:, input_schema:}` maps
  - `:mcp_servers` - MCP server configs for server-side MCP, or `nil`
  - `:task_budget_remaining` - the remaining task budget after in-turn compaction, or `nil`
  """

  alias Normandy.Components.Message

  @enforce_keys [:model, :messages, :max_tokens]
  defstruct model: nil,
            system: nil,
            messages: [],
            response_model: nil,
            temperature: nil,
            max_tokens: nil,
            tools: [],
            mcp_servers: nil,
            task_budget_remaining: nil

  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t() | nil,
          messages: [Message.t()],
          response_model: struct() | nil,
          temperature: float() | nil,
          max_tokens: pos_integer(),
          tools: [map()],
          mcp_servers: [struct() | map()] | nil,
          task_budget_remaining: non_neg_integer() | nil
        }
end
