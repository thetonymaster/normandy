defmodule Normandy.Test.ConflictStore do
  @moduledoc "A MemoryStore whose get/3 always finds a document and whose writes always conflict."
  @behaviour Normandy.Behaviours.MemoryStore
  def list(_, _, _), do: {:ok, []}
  def get(_, _, _), do: {:ok, %{content: "alpha\nbeta", version: 1}}
  def put(_, _, _, _, _), do: {:error, :conflict}
  def delete(_, _, _, _), do: {:error, :conflict}
  def delete_tree(_, _, _), do: {:ok, 0}
  def rename(_, _, _, _), do: :not_found
  def delete_namespace(_, _), do: :ok
end

defmodule Normandy.Test.DownStore do
  @moduledoc "A MemoryStore whose every call is a backend failure."
  @behaviour Normandy.Behaviours.MemoryStore
  def list(_, _, _), do: {:error, :timeout}
  def get(_, _, _), do: {:error, :timeout}
  def put(_, _, _, _, _), do: {:error, :timeout}
  def delete(_, _, _, _), do: {:error, :timeout}
  def delete_tree(_, _, _), do: {:error, :timeout}
  def rename(_, _, _, _), do: {:error, :timeout}
  def delete_namespace(_, _), do: {:error, :timeout}
end

defmodule Normandy.Test.DirDownStore do
  @moduledoc "A MemoryStore where documents are never found and the directory calls (list/delete_tree) fail."
  @behaviour Normandy.Behaviours.MemoryStore
  def list(_, _, _), do: {:error, :timeout}
  def get(_, _, _), do: :not_found
  def put(_, _, _, _, _), do: {:error, :timeout}
  def delete(_, _, _, _), do: :not_found
  def delete_tree(_, _, _), do: {:error, :timeout}
  def rename(_, _, _, _), do: {:error, :timeout}
  def delete_namespace(_, _), do: {:error, :timeout}
end
