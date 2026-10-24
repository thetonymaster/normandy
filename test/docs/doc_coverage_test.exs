defmodule Normandy.Docs.DocCoverageTest do
  @moduledoc """
  Public API has docs (DX-10, decision 27 C5). ExDoc renders an undocumented function
  with an empty body and no warning, so the compiled docs chunks are checked instead:
  every function, macro and callback of every lib/ module with a docs page has a @doc.
  """
  use ExUnit.Case, async: true

  @kinds [:function, :macro, :callback, :macrocallback]

  test "every visible module documents its functions, macros and callbacks" do
    {:ok, modules} = :application.get_key(:normandy, :modules)

    missing =
      for mod <- Enum.sort(modules),
          lib_module?(mod),
          not protocol_impl?(mod),
          moduledoc(mod) != :hidden,
          item <- undocumented(mod),
          do: item

    assert missing == [], "expected @doc on: #{inspect(missing)}"
  end

  test "the Normandy moduledoc says which entry point to use" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy)
    assert doc =~ "## Choosing an entry point"

    for mod <- ~w(Agents.BaseAgent DSL.Agent Coordination.AgentProcess Agents.Turn.Session) do
      assert doc =~ "| `Normandy.#{mod}` |", "expected a table row for Normandy.#{mod}"
    end
  end

  # "Module:kind:name/arity" for each function, macro or callback with no @doc.
  defp undocumented(mod) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    for {{kind, name, arity}, _, _, :none, _} <- docs,
        kind in @kinds,
        do: "#{inspect(mod)}:#{kind}:#{name}/#{arity}"
  end

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
