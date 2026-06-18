if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionRegistry.Redis.Via do
    @moduledoc """
    `:via` callbacks for `SessionRegistry.Redis`, delegating to the local owner
    GenServer. A `Turn.Server` started under `{:via, __MODULE__, {owner, session_id}}`
    registers atomically at process start (`SET … NX`); a losing concurrent start gets
    `{:error, {:already_started, pid}}` and the router routes to the winner.
    """
    alias Normandy.Behaviours.SessionRegistry.Redis, as: Reg

    def register_name({owner, sid}, pid) do
      case Reg.register(owner, sid, pid) do
        :ok ->
          :yes

        {:error, :taken} ->
          :no

        {:error, reason} ->
          # A transport/Redis failure is not contention. Returning :no would
          # masquerade an outage as a lost race and route to a nonexistent
          # winner — crash loud and diagnosable instead of a silent fallback.
          raise "SessionRegistry.Redis.Via: register failed for " <>
                  "#{inspect({owner, sid})}: #{inspect(reason)}"
      end
    end

    def whereis_name({owner, sid}) do
      case Reg.whereis(owner, sid) do
        {:ok, pid} -> pid
        :none -> :undefined
      end
    end

    def unregister_name({owner, sid}) do
      :ok = Reg.unregister(owner, sid)
      :ok
    end

    def send(name, msg) do
      case whereis_name(name) do
        :undefined -> :erlang.error(:badarg, [name, msg])
        pid -> Kernel.send(pid, msg)
      end
    end
  end
end
