defmodule Normandy.Docs.DocCoverageTest do
  @moduledoc """
  Public API has docs (DX-10, decision 27 C5). ExDoc renders an undocumented function
  with an empty body and no warning, so the compiled docs chunks are checked instead.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Session

  @kinds [:function, :macro, :callback, :macrocallback]

  test "BaseAgent and Turn.Session document every public function" do
    missing = Enum.flat_map([BaseAgent, Session], &undocumented/1)
    assert missing == [], "expected @doc on: #{inspect(missing)}"
  end

  test "the Normandy moduledoc says which entry point to use" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Normandy)
    assert doc =~ "## Choosing an entry point"

    for mod <- ~w(Agents.BaseAgent DSL.Agent Coordination.AgentProcess Agents.Turn.Session) do
      assert doc =~ "| `Normandy.#{mod}` |", "expected a table row for Normandy.#{mod}"
    end
  end

  # `{module, kind, name, arity}` for each function, macro or callback with no @doc.
  defp undocumented(mod) do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    for {{kind, name, arity}, _, _, :none, _} <- docs,
        kind in @kinds,
        do: {mod, kind, name, arity}
  end
end
