defmodule Normandy.Docs.DocsGroupsTest do
  @moduledoc """
  HexDocs layout (DX-13, REL-7, decision 27 C1): internals are hidden, and every
  module with docs is in exactly one `groups_for_modules` group in `mix.exs`.
  """
  use ExUnit.Case, async: true

  # Implementation details: `@moduledoc false` (decision 27 C1).
  @hidden [
    Normandy.Agents.Turn.Driver,
    Normandy.Agents.ValidationMiddleware,
    Normandy.Behaviours.SessionRegistry.Horde.Via,
    Normandy.Behaviours.SessionRegistry.Redis.Via,
    Normandy.Hooks.Handlers,
    Normandy.Hooks.Runner,
    Normandy.LLM.Json.ContentCleaner,
    Normandy.LLM.Json.Decoder,
    Normandy.LLM.Json.RetryFeedback,
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

  test "every lib/ module with docs is in exactly one docs group" do
    grouped =
      for {group, mods} <- groups(), mod <- mods do
        assert is_atom(mod),
               "expected module atoms in group #{inspect(group)}, got: #{inspect(mod)}"

        mod
      end

    {:ok, modules} = :application.get_key(:normandy, :modules)

    documented =
      for mod <- modules,
          lib_module?(mod),
          not protocol_impl?(mod),
          moduledoc(mod) != :hidden,
          do: mod

    counts = Enum.frequencies(grouped)
    ungrouped = documented |> Enum.reject(&Map.has_key?(counts, &1)) |> Enum.sort()
    duplicated = for {mod, n} <- counts, n > 1, do: mod
    unknown = Enum.sort(Map.keys(counts) -- documented)

    assert ungrouped == [], "expected a docs group in mix.exs for: #{inspect(ungrouped)}"

    assert duplicated == [],
           "expected one docs group each, found several for: #{inspect(duplicated)}"

    assert unknown == [],
           "expected documented lib/ modules only, found hidden, protocol impl or missing: " <>
             inspect(unknown)
  end

  test "the README's API documentation line names every docs group" do
    [line] = Regex.run(~r/^- \*\*📚 \[API documentation\].*$/m, File.read!("README.md"))

    missing =
      for {group, _mods} <- groups(), not String.contains?(line, to_string(group)), do: group

    assert missing == [], "expected the README to name the docs groups #{inspect(missing)}"
  end

  defp groups,
    do: Mix.Project.config() |> Keyword.fetch!(:docs) |> Keyword.fetch!(:groups_for_modules)

  # test/support modules are in :normandy's module list in the test env.
  defp lib_module?(mod) do
    Code.ensure_loaded!(mod)
    source = mod.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
    String.starts_with?(Path.relative_to_cwd(source), "lib/")
  end

  # ExDoc lists no protocol implementation.
  defp protocol_impl?(mod), do: function_exported?(mod, :__impl__, 1)

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(mod)
    moduledoc
  end
end
