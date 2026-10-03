defmodule Normandy.Behaviours.MemoryStore.Docs do
  @moduledoc false
  # Pure operations on one namespace's documents, `%{path => %{content, version,
  # updated_at}}`. InMemory, ETS and Mnesia run these inside their single serialized
  # writer (an Agent call, the ETS owner, a Mnesia transaction), which makes each atomic.
  # Every write returns `{reply, docs}`.

  alias Normandy.Behaviours.MemoryStore

  def list(docs, prefix) do
    docs
    |> Enum.filter(fn {path, _} -> MemoryStore.at_or_under?(path, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(MemoryStore.list_limit())
    |> Enum.map(fn {path, d} ->
      %{path: path, size: byte_size(d.content), updated_at: d.updated_at}
    end)
  end

  def get(docs, path) do
    case Map.fetch(docs, path) do
      {:ok, d} -> {:ok, %{content: d.content, version: d.version}}
      :error -> :not_found
    end
  end

  def put(docs, path, content, expected) do
    case {Map.get(docs, path), expected} do
      {nil, e} when e in [:new, :any] -> write(docs, path, content, 1)
      {%{version: v}, :any} -> write(docs, path, content, v + 1)
      {%{version: v}, v} -> write(docs, path, content, v + 1)
      _ -> {{:error, :conflict}, docs}
    end
  end

  def delete(docs, path, expected) do
    case {Map.get(docs, path), expected} do
      {nil, _} -> {:not_found, docs}
      {_, :any} -> {:ok, Map.delete(docs, path)}
      {%{version: v}, v} -> {:ok, Map.delete(docs, path)}
      _ -> {{:error, :conflict}, docs}
    end
  end

  def delete_tree(docs, prefix) do
    {gone, kept} =
      Map.split_with(docs, fn {path, _} -> MemoryStore.at_or_under?(path, prefix) end)

    {{:ok, map_size(gone)}, kept}
  end

  def rename(docs, from, to) do
    moving =
      if Map.has_key?(docs, from),
        do: [from],
        else: docs |> Map.keys() |> Enum.filter(&MemoryStore.under?(&1, from))

    cond do
      moving == [] ->
        {:not_found, docs}

      Enum.any?(Map.keys(docs), &MemoryStore.at_or_under?(&1, to)) ->
        {{:error, :exists}, docs}

      true ->
        moved = Map.new(moving, &{MemoryStore.reparent(&1, from, to), Map.fetch!(docs, &1)})
        {{:ok, length(moving)}, docs |> Map.drop(moving) |> Map.merge(moved)}
    end
  end

  defp write(docs, path, content, version) do
    doc = %{content: content, version: version, updated_at: DateTime.utc_now()}
    {{:ok, version}, Map.put(docs, path, doc)}
  end
end
