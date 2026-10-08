# tools/api_diff/cli.exs: command line for tools/api_diff/api_diff.exs; see the README.
Code.require_file("api_diff.exs", __DIR__)

defmodule NormandyTools.ApiDiff.CLI do
  @moduledoc false
  alias NormandyTools.ApiDiff

  def main(["dump", ebin, out]),
    do: File.write!(out, :erlang.term_to_binary(ApiDiff.dump(ebin)))

  def main(["compare", base, head, migrating, reviewed]) do
    diff = ApiDiff.diff(read_term(base), read_term(head))

    for {section, items} <- Enum.sort(diff) do
      IO.puts("## #{section} (#{length(items)})")
      Enum.each(items, &IO.puts/1)
    end

    reviewed = reviewed |> File.read!() |> ApiDiff.parse_reviewed()

    case ApiDiff.unmatched(diff, File.read!(migrating), reviewed) do
      [] ->
        IO.puts("## unmatched (0)")

      items ->
        IO.puts("## unmatched (#{length(items)})")
        Enum.each(items, &IO.puts/1)
        System.halt(1)
    end
  end

  def main(argv) do
    IO.puts(
      :stderr,
      "usage: cli.exs dump <ebin> <out.term> | " <>
        "compare <base.term> <head.term> <MIGRATING.md> <reviewed.txt>; got #{inspect(argv)}"
    )

    System.halt(2)
  end

  defp read_term(path), do: path |> File.read!() |> :erlang.binary_to_term()
end

NormandyTools.ApiDiff.CLI.main(System.argv())
