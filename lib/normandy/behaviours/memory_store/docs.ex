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

  # `limits` are validated (MemoryStore.validate_limits!/2). The whole namespace is in
  # hand, so its totals are exact: no counter to keep.
  def put(docs, path, content, expected, limits \\ []) do
    current = Map.get(docs, path)
    before = totals(docs)

    with {:ok, version} <- next_version(current && current.version, expected),
         :ok <- MemoryStore.check_limits(limits, before, after_put(before, current, content)) do
      write(docs, path, content, version)
    else
      {:error, _reason} = error -> {error, docs}
    end
  end

  @doc false
  # Compare-and-set on a document's current version (`nil` when it is missing). Shared
  # with the Postgres backend.
  @spec next_version(pos_integer() | nil, pos_integer() | :new | :any) ::
          {:ok, pos_integer()} | {:error, :conflict}
  def next_version(nil, expected) when expected in [:new, :any], do: {:ok, 1}
  def next_version(version, :any) when is_integer(version), do: {:ok, version + 1}
  def next_version(version, version) when is_integer(version), do: {:ok, version + 1}
  def next_version(_version, _expected), do: {:error, :conflict}

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

  defp totals(docs),
    do:
      {Enum.reduce(docs, 0, fn {_path, d}, sum -> sum + byte_size(d.content) end), map_size(docs)}

  defp after_put({bytes, count}, nil, content), do: {bytes + byte_size(content), count + 1}

  defp after_put({bytes, count}, %{content: old}, content),
    do: {bytes - byte_size(old) + byte_size(content), count}

  defp write(docs, path, content, version) do
    doc = %{content: content, version: version, updated_at: DateTime.utc_now()}
    {{:ok, version}, Map.put(docs, path, doc)}
  end
end
