defmodule Normandy.LLM.Response do
  @moduledoc """
  A model's answer to one `Normandy.LLM.Request`.

  - `:content` - the request's `response_model` filled in, or the answer text when the
    request's `response_model` was `nil`
  - `:stop_reason` - why the model stopped (`:end_turn`, `:tool_use`, `:max_tokens`,
    `:stop_sequence`, `:pause_turn`, `:refusal`, `:model_context_window_exceeded`,
    `:compaction`), or `nil` when the client doesn't report one
  - `:usage` - the provider's token usage map, or `nil`
  - `:meta` - per-call facts that are not usage: `:served_by`, `:fallback_model`,
    `:input_transformations`, `:response_id`, `:finish_reason` (the stop reason as a
    string, for telemetry)
  """

  @enforce_keys [:content]
  defstruct content: nil, stop_reason: nil, usage: nil, meta: %{}

  @type stop_reason ::
          :end_turn
          | :tool_use
          | :max_tokens
          | :stop_sequence
          | :pause_turn
          | :refusal
          | :model_context_window_exceeded
          | :compaction
          | atom()

  @type t :: %__MODULE__{
          content: struct() | String.t(),
          stop_reason: stop_reason() | nil,
          usage: map() | nil,
          meta: map()
        }
end
