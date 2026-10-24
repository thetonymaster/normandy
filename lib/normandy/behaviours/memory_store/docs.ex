defmodule Normandy.Behaviours.MemoryStore.Docs do
  @moduledoc false
  # Pure operations on one namespace, `%{docs: %{path => %{content, version, updated_at}},
  # bytes: total content bytes}` (new/0). Each write keeps `bytes` by its own delta, so a
  # limited put costs the same in a namespace of any size. InMemory runs these inside one
  # Agent call, which makes each atomic. Every write returns `{reply, ns}`. ETS and Mnesia
  # keep a row per document and use MemoryStore.Rows; they share `next_version/2`.

  alias Normandy.Behaviours.MemoryStore

  def new, do: %{docs: %{}, bytes: 0}

  def empty?(%{docs: docs}), do: docs == %{}

  def list(%{docs: docs}, prefix) do
    docs
    |> Enum.filter(fn {path, _} -> MemoryStore.at_or_under?(path, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(MemoryStore.list_limit())
    |> Enum.map(fn {path, d} ->
      %{path: path, size: byte_size(d.content), updated_at: d.updated_at}
    end)
  end

  def get(%{docs: docs}, path) do
    case Map.fetch(docs, path) do
      {:ok, d} -> {:ok, %{content: d.content, version: d.version}}
      :error -> :not_found
    end
  end

  # `limits` are validated (MemoryStore.validate_limits!/2).
  def put(%{docs: docs, bytes: bytes} = ns, path, content, expected, limits \\ []) do
    current = Map.get(docs, path)
    before = {bytes, map_size(docs)}
    {bytes_after, _documents} = totals = after_put(before, current, content)

    with {:ok, version} <- next_version(current && current.version, expected),
         :ok <- MemoryStore.check_limits(limits, before, totals) do
      write(ns, path, content, version, bytes_after)
    else
      {:error, _reason} = error -> {error, ns}
    end
  end

  @doc false
  # Compare-and-set on a document's current version (`nil` when it is missing). Shared
  # with MemoryStore.Rows and the Postgres backend.
  @spec next_version(pos_integer() | nil, pos_integer() | :new | :any) ::
          {:ok, pos_integer()} | {:error, :conflict}
  def next_version(nil, expected) when expected in [:new, :any], do: {:ok, 1}
  def next_version(version, :any) when is_integer(version), do: {:ok, version + 1}
  def next_version(version, version) when is_integer(version), do: {:ok, version + 1}
  def next_version(_version, _expected), do: {:error, :conflict}

  def delete(%{docs: docs} = ns, path, expected) do
    case {Map.get(docs, path), expected} do
      {nil, _} -> {:not_found, ns}
      {doc, :any} -> {:ok, drop(ns, path, doc)}
      {%{version: v} = doc, v} -> {:ok, drop(ns, path, doc)}
      _ -> {{:error, :conflict}, ns}
    end
  end

  def delete_tree(%{docs: docs, bytes: bytes}, prefix) do
    {gone, kept} =
      Map.split_with(docs, fn {path, _} -> MemoryStore.at_or_under?(path, prefix) end)

    {{:ok, map_size(gone)}, %{docs: kept, bytes: bytes - content_bytes(gone)}}
  end

  def rename(%{docs: docs} = ns, from, to) do
    moving =
      if Map.has_key?(docs, from),
        do: [from],
        else: docs |> Map.keys() |> Enum.filter(&MemoryStore.under?(&1, from))

    cond do
      moving == [] ->
        {:not_found, ns}

      Enum.any?(Map.keys(docs), &MemoryStore.at_or_under?(&1, to)) ->
        {{:error, :exists}, ns}

      true ->
        moved = Map.new(moving, &{MemoryStore.reparent(&1, from, to), Map.fetch!(docs, &1)})
        {{:ok, length(moving)}, %{ns | docs: docs |> Map.drop(moving) |> Map.merge(moved)}}
    end
  end

  defp content_bytes(docs),
    do: Enum.reduce(docs, 0, fn {_path, d}, sum -> sum + byte_size(d.content) end)

  defp drop(%{docs: docs, bytes: bytes}, path, doc),
    do: %{docs: Map.delete(docs, path), bytes: bytes - byte_size(doc.content)}

  defp after_put({bytes, count}, nil, content), do: {bytes + byte_size(content), count + 1}

  defp after_put({bytes, count}, %{content: old}, content),
    do: {bytes - byte_size(old) + byte_size(content), count}

  defp write(%{docs: docs}, path, content, version, bytes) do
    doc = %{content: content, version: version, updated_at: DateTime.utc_now()}
    {{:ok, version}, %{docs: Map.put(docs, path, doc), bytes: bytes}}
  end
end
