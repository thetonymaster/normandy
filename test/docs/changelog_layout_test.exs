defmodule Normandy.Docs.ChangelogLayoutTest do
  @moduledoc """
  Task 7.4b (REL-5, decision 27 C6): cog inserts each release's section at the first
  `- - -` line, so the hand-written 2.0 notes sit after a separator with nothing but the
  preamble and cog's own `## [vX.Y.Z]` sections above them (none before the 2.0 release).
  """
  use ExUnit.Case, async: true

  @lines Path.expand("../../CHANGELOG.md", __DIR__) |> File.read!() |> String.split("\n")

  test "no Unreleased block remains" do
    refute Enum.any?(@lines, &String.starts_with?(&1, "## [Unreleased]"))
  end

  test "the 2.0 notes follow a separator, below only cog's release sections" do
    separator = Enum.find_index(@lines, &(&1 == "- - -"))
    notes = Enum.find_index(@lines, &(&1 == "## Normandy 2.0 release notes"))
    v1_3 = Enum.find_index(@lines, &String.starts_with?(&1, "## [v1.3.0]"))
    # cog bump puts its `- - -` / `## [vX.Y.Z]` section above the notes (and a blank line
    # before them), so the test holds before and after every release.
    above = @lines |> Enum.take(notes) |> Enum.reject(&(&1 == ""))

    assert List.last(above) == "- - -"
    assert notes < v1_3
    assert Enum.at(@lines, v1_3 - 1) == "- - -"
    refute @lines |> Enum.take(separator) |> Enum.any?(&String.starts_with?(&1, "## "))

    assert above
           |> Enum.filter(&String.starts_with?(&1, "## "))
           |> Enum.all?(&(&1 =~ ~r/^## \[v\d/))
  end

  test "the notes send upgraders to MIGRATING-2.0.md" do
    notes = Enum.find_index(@lines, &(&1 == "## Normandy 2.0 release notes"))
    v1_3 = Enum.find_index(@lines, &String.starts_with?(&1, "## [v1.3.0]"))
    assert @lines |> Enum.slice(notes..v1_3) |> Enum.join("\n") =~ "MIGRATING-2.0.md"
  end
end
