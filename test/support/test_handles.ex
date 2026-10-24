defmodule Normandy.TestHandles do
  @moduledoc false
  # The handles the test suite builds its Redis and Postgres stores on. The URL and the
  # Repo come from config/test.exs; namespaces and prefixes are unique per call.

  alias Normandy.Behaviours.MemoryStore.Redis, as: MemoryRedis
  alias Normandy.Behaviours.SessionRegistry.Redis, as: RegistryRedis
  alias Normandy.Behaviours.SessionStore.Redis, as: StoreRedis

  @spec redis_url() :: String.t()
  def redis_url, do: Application.fetch_env!(:normandy, :redis_url)

  @spec redis_session_store(keyword()) :: tuple()
  def redis_session_store(opts \\ []) do
    opts
    |> Keyword.put_new(:url, redis_url())
    |> Keyword.put_new_lazy(:namespace, fn -> "normandy_test_#{UUID.uuid4()}" end)
    |> StoreRedis.new()
  end

  @spec redis_memory_store(keyword()) :: {pid(), String.t()}
  def redis_memory_store(opts \\ []) do
    opts
    |> Keyword.put_new(:url, redis_url())
    |> Keyword.put_new_lazy(:prefix, fn -> "normandy_test_mem_#{UUID.uuid4()}" end)
    |> MemoryRedis.new()
  end

  @spec redis_registry(keyword()) :: RegistryRedis.Handle.t()
  def redis_registry(opts \\ []) do
    opts
    |> Keyword.put_new(:url, redis_url())
    |> Keyword.put_new_lazy(:namespace, fn -> "normandy_reg_#{UUID.uuid4()}" end)
    |> RegistryRedis.new()
  end

  @spec postgres_repo() :: module()
  def postgres_repo, do: hd(Application.fetch_env!(:normandy, :ecto_repos))
end
