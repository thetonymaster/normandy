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
    # Fallback for `pid != self()`. NOTE: `Registry.register/3` always registers
    # the CALLING process, never `pid` — the third arg is the stored *value*, not
    # the pid to register. So this clause registers the caller under `session_id`
    # with `pid` as metadata; it does NOT track the foreign pid's liveness.
    # Nothing in Normandy hits this path: `Turn.Server` self-registers (first
    # clause) and the contract test self-registers from inside the spawned
    # process. Correct foreign-pid registration would require a `:via`-tuple start.
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
