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

defmodule Normandy.Test.RawErrorStore do
  @moduledoc "A MemoryStore whose handle is the reason every call fails with."
  @behaviour Normandy.Behaviours.MemoryStore
  def list(reason, _, _), do: {:error, reason}
  def get(reason, _, _), do: {:error, reason}
  def put(reason, _, _, _, _), do: {:error, reason}
  def delete(reason, _, _, _), do: {:error, reason}
  def delete_tree(reason, _, _), do: {:error, reason}
  def rename(reason, _, _, _), do: {:error, reason}
  def delete_namespace(reason, _), do: {:error, reason}
end

defmodule Normandy.Test.RecordingStore do
  @moduledoc "A MemoryStore whose handle is a pid that is told about every get/list; nothing is ever stored."
  @behaviour Normandy.Behaviours.MemoryStore
  def list(pid, _, _) do
    send(pid, {:call, :list})
    {:ok, []}
  end

  def get(pid, _, _) do
    send(pid, {:call, :get})
    :not_found
  end

  def put(_, _, _, _, _), do: {:ok, 1}
  def delete(_, _, _, _), do: :not_found
  def delete_tree(_, _, _), do: {:ok, 0}
  def rename(_, _, _, _), do: {:ok, 1}
  def delete_namespace(_, _), do: :ok
end

defmodule Normandy.Test.FullListStore do
  @moduledoc "A MemoryStore with no document at any path whose list always returns a full page."
  @behaviour Normandy.Behaviours.MemoryStore
  alias Normandy.Behaviours.MemoryStore

  def list(_, _, prefix) do
    {:ok,
     for i <- 1..MemoryStore.list_limit() do
       %{path: prefix <> "/f#{i}", size: 1, updated_at: DateTime.utc_now()}
     end}
  end

  def get(_, _, _), do: :not_found
  def put(_, _, _, _, _), do: {:ok, 1}
  def delete(_, _, _, _), do: :not_found
  def delete_tree(_, _, _), do: {:ok, 0}
  def rename(_, _, _, _), do: {:ok, 1}
  def delete_namespace(_, _), do: :ok
end
