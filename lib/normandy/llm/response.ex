defmodule Normandy.LLM.Response do
  @moduledoc """
  A model's answer to one `Normandy.LLM.Request`.

  - `:content` - the request's `response_model` filled in, or the answer text when the
    request's `response_model` was `nil`
  - `:stop_reason` - why the model stopped (`:end_turn`, `:tool_use`, `:max_tokens`,
    `:stop_sequence`, `:pause_turn`, `:refusal`, `:model_context_window_exceeded`,
    `:compaction`); an unrecognized provider reason is passed through as a string; `nil`
    when the client doesn't report one
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
          | String.t()

  @type t :: %__MODULE__{
          content: struct() | String.t(),
          stop_reason: stop_reason() | nil,
          usage: map() | nil,
          meta: map()
        }

  @known_stop_reasons [
    :end_turn,
    :tool_use,
    :max_tokens,
    :stop_sequence,
    :pause_turn,
    :refusal,
    :model_context_window_exceeded,
    :compaction
  ]

  @doc false
  # A stop reason in this struct's form: a streamed one (a string in message_delta)
  # becomes its atom when Normandy knows it; an unknown one stays the provider's string.
  @spec stop_reason(atom() | String.t()) :: stop_reason() | nil
  def stop_reason(reason) when is_atom(reason), do: reason

  def stop_reason(reason) when is_binary(reason),
    do: Enum.find(@known_stop_reasons, reason, &(Atom.to_string(&1) == reason))
end
