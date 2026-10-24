defmodule Normandy.Docs.DevexDocsTest do
  @moduledoc """
  Devex Tier 3-4 docs fixes (DX-20, DX-32, DX-34, DX-35) stay fixed.
  """
  use ExUnit.Case, async: true

  # Files whose `iex>` examples run as doctests (`doctest` in a test module).
  @doctested [
    "lib/normandy/components/agent_memory.ex",
    "lib/normandy/components/system_prompt_generator.ex",
    "lib/normandy/coordination/pattern.ex",
    "lib/normandy/telemetry/usage.ex",
    "lib/normandy/tools/input.ex",
    "lib/normandy/type.ex"
  ]

  test "DX-32: every iex> example in lib/ is doctested" do
    with_examples =
      for path <- Path.wildcard("lib/**/*.ex"),
          File.read!(path) =~ ~r/^\s*iex>/m,
          do: path

    undoctested = Enum.sort(with_examples -- @doctested)

    assert undoctested == [],
           "expected iex> examples only in doctested files, found them in: " <>
             inspect(undoctested)
  end

  test "DX-34: the README and the guides name one model, claude-opus-5-5" do
    ids =
      for path <- ["README.md" | Path.wildcard("docs/guides/*.md")],
          [id] <- Regex.scan(~r/claude-(?:opus|sonnet|haiku)-[0-9][\w-]*/, File.read!(path)),
          id != "claude-opus-5-5",
          do: {path, id}

    assert ids == [], "expected only claude-opus-5-5, found: #{inspect(ids)}"
  end

  test "DX-35: the Hex package ships MIGRATING-2.0.md" do
    files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)
    assert "MIGRATING-2.0.md" in files
  end

  describe "DX-20: Postgres store setup" do
    test "SessionStore.Postgres documents the Repo handle and its four migrations in order" do
      doc = moduledoc(Normandy.Behaviours.SessionStore.Postgres)
      assert doc =~ "`{Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo}`"
      refute doc =~ "repo: MyApp.Repo"

      assert doc =~
               "`Normandy.Behaviours.SessionStore.Postgres.Migration`, `MigrationAddTemplate`, " <>
                 "`MigrationAddResumePolicy` and `MigrationAddInflight`, in that order"
    end

    test "MemoryStore.Postgres documents the Repo handle" do
      assert moduledoc(Normandy.Behaviours.MemoryStore.Postgres) =~
               "`{Normandy.Behaviours.MemoryStore.Postgres, MyApp.Repo}`"
    end
  end

  defp moduledoc(mod) do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(mod)
    String.replace(doc, ~r/\s+/, " ")
  end
end
