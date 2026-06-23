# Compiled only when Horde is available (an `optional` dep). Tier-0/1 users who omit
# Horde simply don't get this module; Tier-2 users add it.
if Code.ensure_loaded?(Horde.Registry) do
  defmodule Normandy.Behaviours.SessionRegistry.Horde do
    @moduledoc """
    Distributed `SessionRegistry` over `Horde.Registry` (`keys: :unique`,
    `members: :auto`). The `handle` is the registry's name (an atom). Cluster-wide
    `whereis`; registration is atomic when servers start under the `:via` name from
    `child_name/2`. Works as a cluster-of-one on a single node (and on
    `nonode@nohost`) with the same config that serves N nodes.
    """
    @behaviour Normandy.Behaviours.SessionRegistry

    @doc "Start a unique Horde.Registry. `:name` defaults to this module."
    @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
    def start_link(opts \\ []) do
      name = Keyword.get(opts, :name, __MODULE__)
      Horde.Registry.start_link(name: name, keys: :unique, members: :auto)
    end

    @doc """
    Convenience for tests: start a uniquely-named registry and return its name.

    Waits until the registry actually accepts a registration before returning. A
    fresh `members: :auto` registry transiently rejects registrations (and `:via`
    starts) with `:process_not_registered_via` until it converges; gating here keeps
    test setup from racing that window. Production starts the registry in a
    supervision tree (it is ready long before any session), so this gate is `new/1`
    only.
    """
    @spec new(keyword()) :: atom()
    def new(opts \\ []) do
      name = Keyword.get_lazy(opts, :name, fn -> unique_name() end)
      {:ok, _pid} = start_link(name: name)
      :ok = await_ready(name)
      name
    end

    defp await_ready(name, retries \\ 200) do
      probe = {:__ready_probe__, System.unique_integer([:positive])}

      accepted? =
        try do
          case Horde.Registry.register(name, probe, nil) do
            {:ok, _} ->
              Horde.Registry.unregister(name, probe)
              true

            _ ->
              false
          end
        catch
          :exit, _ -> false
        end

      cond do
        accepted? ->
          :ok

        retries == 0 ->
          :ok

        true ->
          Process.sleep(5)
          await_ready(name, retries - 1)
      end
    end

    @impl true
    def whereis(handle, session_id) do
      case Horde.Registry.lookup(handle, session_id) do
        [{pid, _value}] -> {:ok, pid}
        [] -> :none
      end
    end

    @impl true
    def register(handle, session_id, pid) when pid == self() do
      case Horde.Registry.register(handle, session_id, nil) do
        {:ok, _} -> :ok
        {:error, {:already_registered, _}} -> {:error, :taken}
      end
    end

    def register(handle, session_id, _pid) do
      # Foreign-pid registration is unsupported here (as with Native); distributed
      # servers self-register via the `:via` start (see child_name/2). Kept for the
      # contract's self-registration path.
      case Horde.Registry.register(handle, session_id, nil) do
        {:ok, _} -> :ok
        {:error, {:already_registered, _}} -> {:error, :taken}
      end
    end

    @impl true
    def unregister(handle, session_id) do
      Horde.Registry.unregister(handle, session_id)
      :ok
    end

    @doc "Via-name for an atomic, supervisor-driven start (see SessionRegistry.child_name/2)."
    @impl true
    def child_name(handle, session_id), do: {:via, Horde.Registry, {handle, session_id}}

    defp unique_name do
      String.to_atom(
        "horde_session_registry_" <> Integer.to_string(System.unique_integer([:positive]))
      )
    end
  end
end
