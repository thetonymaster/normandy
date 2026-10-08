defmodule NormandyTools.ApiDiffTest do
  @moduledoc """
  Task 7.1a (decision 27 C4, R3): tools/api_diff dumps the public API from compiled docs,
  diffs two dumps, and lists the removed or changed items MIGRATING-2.0.md does not name.
  """
  use ExUnit.Case, async: true

  Code.require_file("../../tools/api_diff/api_diff.exs", __DIR__)

  alias NormandyTools.ApiDiff

  @base %{
    modules: MapSet.new(["Normandy.A", "Normandy.Gone"]),
    functions:
      MapSet.new([
        "Normandy.A.keep/1 function",
        "Normandy.A.drop/2 function",
        "Normandy.A.cb/1 callback",
        "Normandy.Gone.f/0 function"
      ]),
    specs: %{"Normandy.A.keep/1" => "keep(integer()) :: :ok"},
    structs: %{"Normandy.A" => [:a, :b]}
  }

  @head %{
    modules: MapSet.new(["Normandy.A"]),
    functions: MapSet.new(["Normandy.A.keep/1 function", "Normandy.A.cb/2 callback"]),
    specs: %{"Normandy.A.keep/1" => "keep(integer()) :: {:ok, term()}"},
    structs: %{"Normandy.A" => [:a]}
  }

  test "diff/2 lists removed modules, functions, changed specs and removed fields" do
    assert ApiDiff.diff(@base, @head) == %{
             removed_modules: ["Normandy.Gone"],
             # Normandy.Gone.f/0 is covered by its module's removal.
             removed_functions: ["Normandy.A.cb/1 callback", "Normandy.A.drop/2 function"],
             changed_specs: ["Normandy.A.keep/1"],
             removed_fields: ["Normandy.A.b field"]
           }
  end

  @migrating """
  # Migrating

  ## 1. Tools

  `Normandy.Tools.Gone` is gone.

  ## 2. Lookups

  - `get_tool/2` became `fetch_tool/2` on `BaseAgent`.
  - `Session.run/2` replies a tuple.

  ## 3. Catalog

  The ModelCatalog behaviour has one callback:

  ```elixir
  @callback context_window(model, opts) :: {:ok, pos_integer()} | {:error, term()}
  ```

  ## 4. Security

  `PolicyEngine.check/2` is unchanged.
  """

  @diff %{
    removed_modules: ["Normandy.Tools.Gone"],
    removed_functions: [
      "Normandy.Agents.BaseAgent.get_tool/2 function",
      "Normandy.Behaviours.BudgetTracker.check/2 callback",
      "Normandy.Behaviours.ModelCatalog.context_window/1 callback"
    ],
    changed_specs: ["Normandy.Agents.Turn.Session.run/2"],
    removed_fields: ["Normandy.Components.StreamEvent.index field"]
  }

  test "unmatched/3 keeps only the items no section names and reviewed.txt does not list" do
    reviewed = MapSet.new(["Normandy.Components.StreamEvent.index"])

    # get_tool: name and BaseAgent in one section. Session.run: `Session.run` in a span.
    # context_window: inside a fenced block, ModelCatalog in the section. check: §4 has a
    # `check` span but never mentions BudgetTracker.
    assert ApiDiff.unmatched(@diff, @migrating, reviewed) == [
             "Normandy.Behaviours.BudgetTracker.check/2 callback"
           ]
  end

  test "parse_reviewed/1 reads key<TAB>reason lines and refuses a line without a reason" do
    assert ApiDiff.parse_reviewed("# comment\n\nNormandy.A.f/1\tspec only\n") ==
             MapSet.new(["Normandy.A.f/1"])

    assert_raise ArgumentError,
                 ~s(api_diff reviewed.txt: expected <key><TAB><reason>, got "Normandy.A.f/1"),
                 fn -> ApiDiff.parse_reviewed("Normandy.A.f/1\n") end
  end

  test "dump/1 reads this build's public API from its docs chunks" do
    snapshot = ApiDiff.dump(Path.join(Mix.Project.build_path(), "lib/normandy/ebin"))

    assert "Normandy.Agents.BaseAgent" in snapshot.modules
    assert "Normandy.Agents.BaseAgent.init/1 function" in snapshot.functions
    assert Map.has_key?(snapshot.specs, "Normandy.Agents.BaseAgent.init/1")
    assert :model in Map.fetch!(snapshot.structs, "Normandy.Agents.BaseAgentConfig")
    # @moduledoc false since Task 7.2a.
    refute "Normandy.Hooks.Runner" in snapshot.modules
    # Protocol implementations are not listed (ExDoc does not list them either).
    refute Enum.any?(
             snapshot.modules,
             &String.starts_with?(&1, "Normandy.Agents.Model.Normandy.")
           )
  end
end
