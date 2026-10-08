defmodule NormandyTools.ApiDiff do
  @moduledoc false
  # Compares the public API of two compiled Normandy trees and lists every removed or
  # changed item that MIGRATING-2.0.md does not name. See tools/api_diff/README.md.
  #
  # dump/1 reads beams; diff/2, unmatched/3 and parse_reviewed/1 are pure. cli.exs is the
  # only code that prints, writes files or halts.

  @kinds [:function, :macro, :callback, :macrocallback]

  @type snapshot :: %{
          modules: MapSet.t(String.t()),
          functions: MapSet.t(String.t()),
          specs: %{String.t() => String.t()},
          structs: %{String.t() => [atom()]}
        }

  @doc "The public API of every beam in `ebin`. Loads the modules to read struct fields."
  @spec dump(Path.t()) :: snapshot()
  def dump(ebin) do
    true = Code.prepend_path(ebin)
    beams = ebin |> Path.join("Elixir.*.beam") |> Path.wildcard() |> Enum.sort()

    Enum.reduce(
      beams,
      %{modules: MapSet.new(), functions: MapSet.new(), specs: %{}, structs: %{}},
      fn beam, acc ->
        mod_atom = beam |> Path.basename(".beam") |> String.to_atom()
        mod = mod_atom |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

        case Code.fetch_docs(beam) do
          {:docs_v1, _, _, _, :hidden, _, _} ->
            acc

          {:docs_v1, _, _, _, _moddoc, _, entries} ->
            if protocol_impl?(mod_atom),
              do: acc,
              else: add_module(acc, mod, mod_atom, beam, entries)

          {:error, reason} ->
            raise "api_diff: no docs chunk in #{beam} (#{inspect(reason)}); compile with docs on"
        end
      end
    )
  end

  # ExDoc does not list protocol implementations; their functions are the protocol's.
  defp protocol_impl?(mod_atom) do
    {:module, ^mod_atom} = Code.ensure_loaded(mod_atom)
    function_exported?(mod_atom, :__impl__, 1)
  end

  defp add_module(acc, mod, mod_atom, beam, entries) do
    funs = public_functions(mod, entries)

    %{
      acc
      | modules: MapSet.put(acc.modules, mod),
        functions: MapSet.union(acc.functions, funs),
        specs: Map.merge(acc.specs, specs(mod, beam, funs)),
        structs: put_struct(acc.structs, mod, mod_atom)
    }
  end

  # "Mod.name/arity kind", default arguments expanded (f/3 with one default is also f/2).
  defp public_functions(mod, entries) do
    for {{kind, name, arity}, _, _, doc, meta} <- entries,
        kind in @kinds,
        doc != :hidden,
        a <- (arity - Map.get(meta, :defaults, 0))..arity//1,
        into: MapSet.new(),
        do: "#{mod}.#{name}/#{a} #{kind}"
  end

  defp specs(mod, beam, funs) do
    visible = MapSet.new(funs, &(&1 |> String.split(" ") |> hd()))

    case Code.Typespec.fetch_specs(File.read!(beam)) do
      {:ok, specs} ->
        for {{name, arity}, clauses} <- specs,
            key = "#{mod}.#{name}/#{arity}",
            MapSet.member?(visible, key),
            into: %{} do
          text =
            clauses
            |> Enum.map_join(
              " ; ",
              &(Code.Typespec.spec_to_quoted(name, &1) |> Macro.to_string())
            )
            |> String.replace(~r/\s+/, " ")

          {key, text}
        end

      :error ->
        %{}
    end
  end

  defp put_struct(structs, mod, mod_atom) do
    if function_exported?(mod_atom, :__struct__, 0) do
      fields = mod_atom.__struct__() |> Map.keys() |> List.delete(:__struct__) |> Enum.sort()
      Map.put(structs, mod, fields)
    else
      structs
    end
  end

  @doc "What `head` removed or changed relative to `base`, as sorted lists of item strings."
  @spec diff(snapshot(), snapshot()) :: %{atom() => [String.t()]}
  def diff(base, head) do
    gone = MapSet.difference(base.modules, head.modules)

    %{
      removed_modules: Enum.sort(gone),
      removed_functions:
        base.functions
        |> MapSet.difference(head.functions)
        |> Enum.reject(&MapSet.member?(gone, module_of(&1)))
        |> Enum.sort(),
      changed_specs:
        Enum.sort(
          for {key, spec} <- base.specs,
              Map.has_key?(head.specs, key),
              Map.fetch!(head.specs, key) != spec,
              do: key
        ),
      removed_fields:
        Enum.sort(
          for {mod, fields} <- base.structs,
              head_fields = Map.get(head.structs, mod),
              is_list(head_fields),
              field <- fields -- head_fields,
              do: "#{mod}.#{field} field"
        )
    }
  end

  defp module_of(item),
    do: item |> key() |> String.replace(~r/\.[^.]+\/\d+$/, "")

  @doc """
  The items of `diff` that `migrating` does not name and `reviewed` does not list.

  Per `## ` section of `migrating`: a module is named when a code span holds its last
  alias segment as a token; a function, callback or field when a code span holds
  `Last.name`, or a code span holds `name` and the section mentions `Last` (the module's
  last alias segment). A fenced block is one code span.
  """
  @spec unmatched(%{atom() => [String.t()]}, String.t(), MapSet.t(String.t())) :: [String.t()]
  def unmatched(diff, migrating, reviewed) do
    sections = sections(migrating)

    diff
    |> Map.values()
    |> List.flatten()
    |> Enum.reject(&(MapSet.member?(reviewed, key(&1)) or named?(&1, sections)))
    |> Enum.sort()
  end

  # "Mod.f/2 function" -> "Mod.f/2"; "Mod.field field" -> "Mod.field"; a module is its own key.
  defp key(item), do: item |> String.split(" ") |> hd()

  defp sections(text) do
    text
    |> String.split(~r/\n(?=## )/)
    |> Enum.map(&{&1, spans(&1)})
  end

  # Fenced blocks count as one span each; then the inline `code` spans outside them.
  defp spans(section) do
    fences = Regex.scan(~r/```[^\n]*\n(.*?)```/s, section, capture: :all_but_first)
    rest = Regex.replace(~r/```.*?```/s, section, "")
    inline = Regex.scan(~r/`([^`]+)`/, rest, capture: :all_but_first)
    List.flatten(fences ++ inline)
  end

  defp named?(item, sections) do
    case String.split(item, " ") do
      [mod] ->
        last = mod |> String.split(".") |> List.last()
        Enum.any?(sections, fn {_text, spans} -> Enum.any?(spans, &token?(&1, last)) end)

      [path, _kind] ->
        member_named?(path, sections)
    end
  end

  defp member_named?(path, sections) do
    [_, mod, name] = Regex.run(~r/^(.+)\.([^.\/]+)(?:\/\d+)?$/, path)
    last = mod |> String.split(".") |> List.last()
    qualified = last <> "." <> name

    Enum.any?(sections, fn {text, spans} ->
      Enum.any?(spans, &token?(&1, qualified)) or
        (Enum.any?(spans, &token?(&1, name)) and String.contains?(text, last))
    end)
  end

  defp token?(span, name),
    do: Regex.match?(~r/(?<![A-Za-z0-9_])#{Regex.escape(name)}(?![A-Za-z0-9_?!])/, span)

  @doc "`reviewed.txt`: one `<key><TAB><reason>` per line; `#` lines and blank lines ignored."
  @spec parse_reviewed(String.t()) :: MapSet.t(String.t())
  def parse_reviewed(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
    |> MapSet.new(fn line ->
      case String.split(line, "\t", parts: 2) do
        [key, reason] when reason != "" ->
          key

        _ ->
          raise ArgumentError,
                "api_diff reviewed.txt: expected <key><TAB><reason>, got #{inspect(line)}"
      end
    end)
  end
end
