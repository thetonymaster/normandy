defmodule Normandy.Behaviours.SessionRegistry.Native do
  @moduledoc """
  Default `SessionRegistry` over Elixir's `Registry` (`:unique` keys). The
  `handle` is the registry's name (an atom). `register/3` registers the calling
  process under `session_id`; the owner's death auto-unregisters it.
  """
  @behaviour Normandy.Behaviours.SessionRegistry

  @doc "Starts a unique Registry. `:name` defaults to this module."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Registry.start_link(keys: :unique, name: name)
  end

  @doc "Convenience: start a uniquely-named Registry and return its name as the handle."
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    name = Keyword.get_lazy(opts, :name, fn -> unique_name() end)
    {:ok, _pid} = start_link(name: name)
    name
  end

  @impl true
  def whereis(handle, session_id) do
    case Registry.lookup(handle, session_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :none
    end
  end

  @impl true
  def register(handle, session_id, pid) when pid == self() do
    case Registry.register(handle, session_id, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _}} -> {:error, :taken}
    end
  end

  def register(handle, session_id, pid) do
    # Register a foreign pid by asking nobody — Registry only registers self().
    # The Turn.Server always registers itself, so this clause exists for the
    # contract test (registering `self()` from the test process) and for any
    # caller that owns `pid`. We register on behalf via a short-lived link only
    # when pid == self(); otherwise fall back to Registry's metadata table.
    case Registry.register(handle, session_id, pid) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _}} -> {:error, :taken}
    end
  end

  @impl true
  def unregister(handle, session_id) do
    Registry.unregister(handle, session_id)
    :ok
  end

  defp unique_name do
    String.to_atom("session_registry_" <> Integer.to_string(System.unique_integer([:positive])))
  end
end
