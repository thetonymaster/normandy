defmodule Normandy.LLM.Request do
  @moduledoc """
  One call to a model: what `Normandy.Agents.Model.converse/3` and
  `Normandy.Agents.Model.stream/3` receive.

  - `:model` - the model id
  - `:system` - the system prompt, or `nil`. `:messages` never holds a `"system"` message.
  - `:output_schema_prompt` - the `# OUTPUT SCHEMA` section that tells the model the
    answer's JSON Schema, or `nil`. It is not in `:system`: an adapter sends it after
    `:system` on every call whose output it does not constrain to that schema, and may
    leave it out of one it does (`ClaudioAdapter` with structured outputs, AX-19).
  - `:context_prompt` - the context providers' `# Context` section, or `nil`: the part of
    the system prompt that can change from call to call, sent last (`ClaudioAdapter` puts
    it after the cached system block, AX-20).

  A `Normandy.Agents.Model` implementation sends `system_prompt/1` as its system prompt.
  - `:messages` - the conversation, oldest first, as `Normandy.Components.Message` structs
  - `:response_model` - an empty struct of the shape the caller expects back (see
    "Response content" in `Normandy.Agents.Model`), or `nil` for the answer as text
  - `:output_format` - on a tool-loop call (`response_model: %ToolCallResponse{}`) or a
    stream, the output-schema struct the final answer's text must match, or `nil`. An
    adapter that supports constrained decoding sends it (`ClaudioAdapter`, as
    `output_config.format`); others ignore it. Never set for the chat schema.
  - `:temperature` - `nil` leaves it unset (Opus 4.7+ reject sampling parameters)
  - `:max_tokens` - required by the Messages API
  - `:tools` - tool schemas, `%{name:, description:, input_schema:}` maps; a tool with a
    provider-defined type also has `:native` (`Normandy.Tool.native_definition/1`), which an
    adapter that supports it sends instead; any other adapter sends the three keys
  - `:mcp_servers` - MCP server configs for server-side MCP, or `nil`
  - `:task_budget_remaining` - the remaining task budget after in-turn compaction, or `nil`
  - `:tool_choice` - `nil` (the provider's default) or `:none`: tools stay listed, but the
    model may not call one. BaseAgent sets `:none` on the call after the last tool round
    (`max_tool_iterations`); a client without tool choice may ignore it
  """

  alias Normandy.Components.Message

  @enforce_keys [:model, :messages, :max_tokens]
  defstruct model: nil,
            system: nil,
            output_schema_prompt: nil,
            context_prompt: nil,
            messages: [],
            response_model: nil,
            output_format: nil,
            temperature: nil,
            max_tokens: nil,
            tools: [],
            mcp_servers: nil,
            task_budget_remaining: nil,
            tool_choice: nil

  @type t :: %__MODULE__{
          model: String.t(),
          system: String.t() | nil,
          output_schema_prompt: String.t() | nil,
          context_prompt: String.t() | nil,
          messages: [Message.t()],
          response_model: struct() | nil,
          output_format: struct() | nil,
          temperature: float() | nil,
          max_tokens: pos_integer(),
          tools: [map()],
          mcp_servers: [struct() | map()] | nil,
          task_budget_remaining: non_neg_integer() | nil,
          tool_choice: :none | nil
        }

  @doc """
  The system prompt for a call whose output the adapter does not constrain: `:system`,
  `:output_schema_prompt` and `:context_prompt`, the ones that are set, a blank line
  apart. `nil` when none is. Takes a request, or a map with those three keys.
  """
  @spec system_prompt(t() | %{system: s, output_schema_prompt: s, context_prompt: s}) ::
          String.t() | nil
        when s: String.t() | nil
  def system_prompt(%{system: system, output_schema_prompt: schema, context_prompt: context}) do
    case Enum.reject([system, schema, context], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  @doc false
  # For providers whose wire format takes the system prompt as the first message
  # (the Claudio request builder, Chat Completions): system_prompt/1 as a leading
  # "system" message, then `:messages`. A constrained call clears :output_schema_prompt
  # first.
  @spec messages_with_system(t()) :: [Message.t()]
  def messages_with_system(%__MODULE__{messages: messages} = request) do
    case system_prompt(request) do
      nil -> messages
      system -> [%Message{role: "system", content: system} | messages]
    end
  end
end
