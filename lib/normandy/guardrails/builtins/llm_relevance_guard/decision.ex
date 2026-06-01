defmodule Normandy.Guardrails.Builtins.LlmRelevanceGuard.Decision do
  @moduledoc """
  Structured output for `Normandy.Guardrails.Builtins.LlmRelevanceGuard`.

  The classifier model populates this from its JSON reply. `on_topic` is the
  single source of truth the guard branches on; a non-boolean value (the default
  `nil`) means the classifier could not produce a decision.
  """

  use Normandy.Schema
  @derive {Poison.Encoder, only: [:on_topic, :reason]}

  io_schema "A relevance classification decision" do
    field(:on_topic, :boolean,
      description: "true if and only if the message concerns the allowed domain",
      required: true
    )

    field(:reason, :string, description: "one short clause explaining the decision")
  end
end
