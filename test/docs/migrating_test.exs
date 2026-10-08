defmodule Normandy.Docs.MigratingTest do
  @moduledoc """
  Task 7.1b (decision 27 C2, C3): MIGRATING-2.0.md's numbered sections run 1..n, its
  "Who is affected" index names only existing sections and every section at least once,
  the closing sections follow the last numbered one, the two breaking items no longer sit
  under "New, non-breaking", and its code fences are balanced.
  """
  use ExUnit.Case, async: true

  @path Path.expand("../../MIGRATING-2.0.md", __DIR__)

  setup_all do
    {:ok, text: File.read!(@path)}
  end

  defp numbered(text),
    do: for([_, n] <- Regex.scan(~r/^## (\d+)\. /m, text), do: String.to_integer(n))

  defp section(text, heading) do
    [_, body] = Regex.run(~r/^#{Regex.escape(heading)}\n(.*?)(?=^## |\z)/ms, text)
    body
  end

  test "numbered sections run 1..n with no gap", %{text: text} do
    numbers = numbered(text)
    assert numbers == Enum.to_list(1..length(numbers))
  end

  test "the index names only existing sections, and every section", %{text: text} do
    index = section(text, "## Who is affected")
    listed = for [_, n] <- Regex.scan(~r/§(\d+)/, index), uniq: true, do: String.to_integer(n)

    assert Enum.sort(listed) == numbered(text),
           "index lists #{inspect(Enum.sort(listed))}, sections are #{inspect(numbered(text))}"
  end

  test "the index comes before section 1, the closing sections after the last one",
       %{text: text} do
    [{index_at, _}] = Regex.run(~r/^## Who is affected$/m, text, return: :index)
    [{first_at, _}] = Regex.run(~r/^## 1\. /m, text, return: :index)
    [{limits_at, _}] = Regex.run(~r/^## Known limits of 2\.0$/m, text, return: :index)
    [{new_at, _}] = Regex.run(~r/^## New, non-breaking$/m, text, return: :index)
    last = numbered(text) |> List.last()
    [{last_at, _}] = Regex.run(~r/^## #{last}\. /m, text, return: :index)

    assert index_at < first_at
    assert last_at < limits_at and limits_at < new_at
  end

  test "breaking changes are not filed under New, non-breaking", %{text: text} do
    new = section(text, "## New, non-breaking")
    refute new =~ "`:fallbacks` is rejected on streaming calls"
    refute new =~ "now raise on an invalid"
  end

  test "code fences are balanced", %{text: text} do
    fences = Regex.scan(~r/^\s*`{3}/m, text)
    assert rem(length(fences), 2) == 0, "#{length(fences)} fence lines"
  end
end
