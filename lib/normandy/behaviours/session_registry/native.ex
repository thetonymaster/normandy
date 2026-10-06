defmodule Normandy.Behaviours.SessionRegistry.Native do
  @moduledoc """
  Default `SessionRegistry` over Elixir's `Registry` (`:unique` keys). The
  `handle` is the registry's name (an atom). `register/3` registers the calling
  process under `session_id`; the owner's death auto-unregisters it.
  """
  @behaviour Normandy.Behaviours.SessionRegistry

  alias Normandy.Options

  @start_link_opts_schema NimbleOptions.new!(
                            name: [
                              type: :atom,
                              default: __MODULE__,
                              doc: "The registry's name, which is also its handle."
                            ]
                          )
  @new_opts_schema NimbleOptions.new!(
                     name: [type: :atom, doc: "The registry's name (default: a unique one)."]
                   )

  @doc """
  Starts a unique `Registry`.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
    Registry.start_link(keys: :unique, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Starts a registry and returns its name as the handle.

  ## Options

  #{Options.docs(@new_opts_schema)}
  """
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
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

  @impl true
  def child_name(_handle, _session_id), do: :self_register

  defp unique_name do
    String.to_atom("session_registry_" <> Integer.to_string(System.unique_integer([:positive])))
  end
end
