defmodule Normandy.Tools.Memory.Commands do
  @moduledoc false
  # The six memory commands. Strings follow Anthropic's memory-tool reference. Each
  # returns {:ok, text, stats} or {:error, error_type, text}; Normandy.Tools.Memory turns
  # that into the tool result and telemetry. Every path is validated (locate/4) before
  # any store call.

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Tools.Memory
  alias Normandy.Tools.Memory.{Paths, Render}

  @root "/memories"

  def run(%Memory{command: nil}, _ns),
    do: {:error, :invalid_input, "Error: no memory command was given"}

  def run(%Memory{command: cmd} = tool, ns) do
    case cmd.command do
      "view" ->
        view(tool, ns, cmd)

      "create" ->
        create(tool, ns, cmd)

      "str_replace" ->
        str_replace(tool, ns, cmd)

      "insert" ->
        insert(tool, ns, cmd)

      "delete" ->
        delete(tool, ns, cmd)

      "rename" ->
        rename(tool, ns, cmd)

      other ->
        {:error, :invalid_input,
         "Error: unknown command #{inspect(other)}; expected one of view, create, str_replace, insert, delete, rename"}
    end
  end

  defp view(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :read) do
      case store(tool, :get, [loc.namespace, loc.path]) do
        {:ok, %{content: content}} ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          with {:ok, text} <-
                 Render.file(loc.model_path, content, cmd.view_range, tool.max_view_chars),
               do: {:ok, text, %{bytes_read: byte_size(content)}}

        :not_found ->
          view_directory(tool, loc)

        {:error, reason} ->
          backend(reason)
      end
    end
  end

  defp view_directory(tool, loc) do
    case store(tool, :list, [loc.namespace, loc.path]) do
      {:ok, []} when loc.path != @root ->
        {:error, :not_found,
         "The path #{loc.model_path} does not exist. Please provide a valid path."}

      {:ok, entries} ->
        docs = Enum.map(entries, &%{path: Paths.to_model(&1.path, loc.mount), size: &1.size})
        limit = MemoryStore.list_limit()

        # list/3 returns at most `limit` entries, so a full page may have been cut short.
        note =
          if length(entries) >= limit,
            do: "\n(listing stopped at #{limit} files; view a subdirectory to see the rest)",
            else: ""

        {:ok, Render.directory(loc.model_path, docs) <> note, %{}}

      {:error, reason} ->
        backend(reason)
    end
  end

  defp create(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         :ok <- not_root(loc, "create a file at"),
         {:ok, text} <- text(cmd, :file_text, loc),
         :ok <- fits(tool, loc, text) do
      case store(tool, :put, [loc.namespace, loc.path, text, :any]) do
        {:ok, _version} ->
          {:ok, "File created successfully at: #{loc.model_path}",
           %{bytes_written: byte_size(text)}}

        {:error, reason} ->
          backend(reason)
      end
    end
  end

  defp str_replace(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         {:ok, old} <- text(cmd, :old_str, loc),
         :ok <- non_empty(old, :old_str),
         {:ok, new} <- optional_text(cmd, :new_str, loc) do
      edit(
        tool,
        loc,
        "Error: The path #{loc.model_path} does not exist. Please provide a valid path.",
        &replace_once(&1, old, new, loc.model_path),
        fn content, info ->
          "The memory file has been edited.\n" <> Render.snippet(content, info.first, info.last)
        end
      )
    end
  end

  defp insert(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         {:ok, text} <- text(cmd, :insert_text, loc),
         {:ok, line} <- integer(cmd.insert_line, :insert_line) do
      edit(
        tool,
        loc,
        "Error: The path #{loc.model_path} does not exist",
        &insert_at(&1, line, text),
        fn _content, _info -> "The file #{loc.model_path} has been edited." end
      )
    end
  end

  defp delete(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         :ok <- not_root(loc, "delete") do
      case store(tool, :delete, [loc.namespace, loc.path, :any]) do
        :ok -> {:ok, "Successfully deleted #{loc.model_path}", %{}}
        :not_found -> delete_directory(tool, loc)
        {:error, reason} -> backend(reason)
      end
    end
  end

  defp delete_directory(tool, loc) do
    case store(tool, :delete_tree, [loc.namespace, loc.path]) do
      {:ok, 0} -> {:error, :not_found, "Error: The path #{loc.model_path} does not exist"}
      {:ok, _n} -> {:ok, "Successfully deleted #{loc.model_path}", %{}}
      {:error, reason} -> backend(reason)
    end
  end

  defp rename(tool, ns, cmd) do
    with {:ok, from} <- locate(tool, ns, cmd.old_path, :write),
         {:ok, to} <- locate(tool, ns, cmd.new_path, :write),
         :ok <- not_root(from, "rename"),
         :ok <- same_mount(from, to) do
      case store(tool, :rename, [from.namespace, from.path, to.path]) do
        {:ok, _n} ->
          {:ok, "Successfully renamed #{from.model_path} to #{to.model_path}", %{}}

        :not_found ->
          {:error, :not_found, "Error: The path #{from.model_path} does not exist"}

        {:error, :exists} ->
          {:error, :exists, "Error: The destination #{to.model_path} already exists"}

        {:error, reason} ->
          backend(reason)
      end
    end
  end

  # Read-modify-write with compare-and-set. A lost race re-reads and re-applies, up to
  # max_cas_retries extra attempts.
  defp edit(tool, loc, missing, transform, success, attempt \\ 0) do
    case store(tool, :get, [loc.namespace, loc.path]) do
      :not_found ->
        {:error, :not_found, missing}

      {:error, reason} ->
        backend(reason)

      {:ok, %{content: content, version: version}} ->
        with {:ok, updated, info} <- transform.(content),
             :ok <- fits(tool, loc, updated) do
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case store(tool, :put, [loc.namespace, loc.path, updated, version]) do
            {:ok, _} ->
              {:ok, success.(updated, info),
               %{
                 bytes_read: byte_size(content),
                 bytes_written: byte_size(updated),
                 cas_retries: attempt
               }}

            {:error, :conflict} when attempt < tool.max_cas_retries ->
              edit(tool, loc, missing, transform, success, attempt + 1)

            {:error, :conflict} ->
              {:error, :conflict_exhausted,
               "Error: #{loc.model_path} was changed by another writer #{attempt + 1} times while editing; view it and retry"}

            {:error, reason} ->
              backend(reason)
          end
        end
    end
  end

  defp replace_once(content, old, new, path) do
    case :binary.matches(content, old) do
      [] ->
        {:error, :no_match,
         "No replacement was performed, old_str `#{old}` did not appear verbatim in #{path}."}

      [{pos, len}] ->
        before = binary_part(content, 0, pos)
        rest = binary_part(content, pos + len, byte_size(content) - pos - len)
        first = line_of(before)
        {:ok, before <> new <> rest, %{first: first, last: first + newlines(new)}}

      many ->
        lines =
          Enum.map_join(many, ", ", fn {pos, _} -> line_of(binary_part(content, 0, pos)) end)

        {:error, :ambiguous_match,
         "No replacement was performed. Multiple occurrences of old_str `#{old}` in lines: #{lines}. Please ensure it is unique"}
    end
  end

  # Lines are counted as view shows them (Render.file/4 drops trailing newlines), so the
  # valid range matches what the model saw; the trailing newlines are kept.
  defp insert_at(content, line, text) do
    body = String.trim_trailing(content, "\n")
    tail = binary_part(content, byte_size(body), byte_size(content) - byte_size(body))
    lines = String.split(body, "\n")
    n = length(lines)

    if line < 0 or line > n do
      {:error, :invalid_line,
       "Error: Invalid `insert_line` parameter: #{line}. It should be within the range of lines of the file: [0, #{n}]"}
    else
      updated =
        lines |> List.insert_at(line, String.trim_trailing(text, "\n")) |> Enum.join("\n")

      {:ok, updated <> tail, %{}}
    end
  end

  defp locate(tool, ns, path, need) do
    with {:ok, path} <- Paths.validate(path) do
      loc = Paths.resolve(path, ns, tool.mounts)

      if need == :write and loc.access == :read_only,
        do: {:error, :read_only, "Error: #{loc.model_path} is read-only"},
        else: {:ok, loc}
    end
  end

  defp not_root(%{path: @root} = loc, verb),
    do: {:error, :invalid_input, "Error: cannot #{verb} the #{loc.model_path} directory"}

  defp not_root(_loc, _verb), do: :ok

  defp same_mount(%{mount: m}, %{mount: m}), do: :ok

  defp same_mount(_from, _to),
    do: {:error, :invalid_input, "Error: cannot rename across mounts"}

  defp fits(tool, loc, text) do
    n = byte_size(text)

    if n > tool.max_document_bytes,
      do:
        {:error, :too_large,
         "Error: #{loc.model_path} would be #{n} bytes; the limit is #{tool.max_document_bytes}"},
      else: :ok
  end

  defp text(cmd, key, loc) do
    case Map.get(cmd, key) do
      s when is_binary(s) -> if String.valid?(s), do: {:ok, s}, else: bad_text(key, loc)
      _ -> bad_text(key, loc)
    end
  end

  defp optional_text(cmd, key, loc),
    do: if(Map.get(cmd, key) == nil, do: {:ok, ""}, else: text(cmd, key, loc))

  # Names the path, like Paths' invalid-UTF-8 error (spec §3).
  defp bad_text(key, loc),
    do: {:error, :invalid_input, "Error: `#{key}` must be a UTF-8 string for #{loc.model_path}"}

  defp non_empty("", key), do: {:error, :invalid_input, "Error: `#{key}` must not be empty"}
  defp non_empty(_s, _key), do: :ok

  defp integer(n, _key) when is_integer(n), do: {:ok, n}
  defp integer(_n, key), do: {:error, :invalid_input, "Error: `#{key}` must be an integer"}

  defp line_of(prefix), do: newlines(prefix) + 1
  defp newlines(s), do: length(:binary.matches(s, "\n"))

  defp store(%Memory{store: {mod, handle}}, fun, args), do: apply(mod, fun, [handle | args])

  defp backend(reason),
    do: {:error, :backend, "Error: memory store unavailable: #{inspect(reason)}"}
end
