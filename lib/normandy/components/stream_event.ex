defmodule Normandy.Components.StreamEvent do
  @moduledoc """
  What a `Normandy.Agents.BaseAgent.stream/3` callback receives, in stream order.

  | `type` | `data` |
  |---|---|
  | `:message_start` | `%{id: String.t() \\| nil, model: String.t() \\| nil}` |
  | `:text_delta` | the new text |
  | `:thinking_delta` | the new thinking text |
  | `:tool_use_start` | `%{id: String.t(), name: String.t()}`; the input arrives later |
  | `:tool_result` | the `%Normandy.Components.ToolResult{}` of a finished tool call |
  | `:guardrail_violation` | `%{stage: :output, mode: :accumulate \\| :incremental, violations: list()}` |
  | `:message_stop` | `nil` |

  With tools, one `stream/3` call streams several model messages, each from
  `:message_start` to `:message_stop`, with `:tool_result` events between them. With
  `max_tool_concurrency > 1`, `:tool_result` events arrive in completion order.
  """

  @enforce_keys [:type]
  defstruct [:type, :data]

  @type type ::
          :message_start
          | :text_delta
          | :thinking_delta
          | :tool_use_start
          | :tool_result
          | :guardrail_violation
          | :message_stop

  @type t :: %__MODULE__{type: type(), data: term()}
end
