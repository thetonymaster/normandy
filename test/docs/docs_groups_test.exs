defmodule Normandy.Docs.DocsGroupsTest do
  @moduledoc """
  HexDocs layout (DX-13, REL-7, decision 27 C1): internals are hidden, and every
  module with docs is in exactly one `groups_for_modules` group in `mix.exs`.
  """
  use ExUnit.Case, async: true

  # Implementation details: `@moduledoc false` (decision 27 C1).
  @hidden [
    Normandy.Agents.Turn.Driver,
    Normandy.Agents.Turn.Inline,
    Normandy.Agents.ValidationMiddleware,
    Normandy.Behaviours.SessionRegistry.Horde.Via,
    Normandy.Behaviours.SessionRegistry.Redis.Via,
    Normandy.Hooks.Handlers,
    Normandy.Hooks.Runner,
    Normandy.LLM.Json.ContentCleaner,
    Normandy.LLM.Json.Decoder,
    Normandy.LLM.Json.RetryFeedback,
    Normandy.LLM.Json.Scanner,
    Normandy.LLM.Json.SchemaBinder,
    Normandy.LLM.Json.SchemaTranslator,
    Normandy.Telemetry.KilledRun,
    Normandy.Telemetry.Metadata,
    Normandy.Telemetry.OtelCtx,
    Normandy.Telemetry.Provider,
    Normandy.Telemetry.WorkflowSpan
  ]

  # Public although internal-looking: adapter authors, hook authors and handler
  # injection use them (decision 27 C1).
  @kept_public [
    Normandy.Agents.Dispatch,
    Normandy.Agents.Dispatch.Invocation,
    Normandy.Agents.Dispatch.Pipeline,
    Normandy.Agents.Turn.Driver.Handlers,
    Normandy.Hooks.Context,
    Normandy.LLM.StructuredOutputs,
    Normandy.Schema.Validator,
    Normandy.Telemetry.Request,
    Normandy.Telemetry.Usage
  ]

  test "internals have no docs page" do
    shown = Enum.reject(@hidden, &(moduledoc(&1) == :hidden))
    assert shown == [], "expected @moduledoc false, found docs on: #{inspect(shown)}"
  end

  test "the public helpers keep their docs page" do
    hidden = Enum.filter(@kept_public, &(moduledoc(&1) == :hidden))
    assert hidden == [], "expected a @moduledoc, found it hidden on: #{inspect(hidden)}"
  end

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(mod)
    moduledoc
  end
end
