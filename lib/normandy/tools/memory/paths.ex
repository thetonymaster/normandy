defmodule Normandy.Tools.Memory.Paths do
  @moduledoc false
  # Path rules for the memory tool. Every path in every command passes validate/1 before
  # any store call. Nothing is ever URL-decoded: `%` is simply not allowed.

  alias Normandy.Behaviours.MemoryStore

  @root "/memories"
  @max_bytes 255

  def root, do: @root

  # The root alone may carry a trailing slash (spec §3); it normalises to the root.
  def validate(@root <> "/"), do: {:ok, @root}

  def validate(path) when is_binary(path) do
    cond do
      not String.valid?(path) -> invalid("path is not valid UTF-8 for #{inspect(path)}")
      # Unicode category Cc (C0, DEL and C1), checked before any error that echoes the path.
      String.match?(path, ~r/\p{Cc}/u) -> invalid("path contains a control character")
      byte_size(path) > @max_bytes -> invalid("path is longer than #{@max_bytes} bytes")
      not MemoryStore.at_or_under?(path, @root) -> invalid("#{path} is outside /memories")
      String.contains?(path, ["\\", "%"]) -> invalid("#{path} contains \\ or %")
      bad_segment?(path) -> invalid("#{path} has an empty, . or .. segment")
      true -> {:ok, path}
    end
  end

  # `got: <inspect>` already names the offending value.
  def validate(other), do: invalid("path must be a string, got: #{inspect(other)}")

  def resolve(path, default_ns, mounts) do
    mounts
    |> Enum.filter(fn {mount, _} -> MemoryStore.at_or_under?(path, mount) end)
    |> Enum.max_by(fn {mount, _} -> byte_size(mount) end, fn -> nil end)
    |> case do
      nil ->
        %{namespace: default_ns, path: path, model_path: path, access: :read_write, mount: nil}

      {mount, {ns, access}} ->
        store_path = MemoryStore.reparent(path, mount, @root)
        %{namespace: ns, path: store_path, model_path: path, access: access, mount: mount}
    end
  end

  def to_model(store_path, nil), do: store_path
  def to_model(store_path, mount), do: MemoryStore.reparent(store_path, @root, mount)

  defp bad_segment?(path) do
    path |> String.split("/") |> tl() |> Enum.any?(&(&1 in ["", ".", ".."]))
  end

  defp invalid(why), do: {:error, :invalid_path, "Error: " <> why}
end
