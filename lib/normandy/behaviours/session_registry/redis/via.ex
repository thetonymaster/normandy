if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.SessionRegistry.Redis.Via do
    @moduledoc """
    `:via` callbacks for `SessionRegistry.Redis`. The name is
    `{%SessionRegistry.Redis.Handle{}, session_id}`; registration goes through the local
    owner GenServer, lookups run in the caller. A `Turn.Server` started under
    `{:via, __MODULE__, {handle, session_id}}`
    registers atomically at process start (`SET … NX`); a losing concurrent start gets
    `{:error, {:already_started, pid}}` and the router routes to the winner.
    """
    alias Normandy.Behaviours.SessionRegistry.Redis, as: Reg
    alias Normandy.Components.ContentBlock.Describe

    def register_name({handle, sid}, pid) do
      case Reg.register(handle, sid, pid) do
        :ok ->
          :yes

        {:error, :taken} ->
          :no

        {:error, reason} ->
          # A transport/Redis failure is not contention. Returning :no would
          # masquerade an outage as a lost race and route to a nonexistent
          # winner — crash loud and diagnosable instead of a silent fallback.
          raise "SessionRegistry.Redis.Via: register failed for session " <>
                  "#{inspect(sid)} in #{inspect(handle.owner)}: #{Describe.reason_tag(reason)}"
      end
    end

    def whereis_name({handle, sid}) do
      case Reg.whereis(handle, sid) do
        {:ok, pid} ->
          pid

        :none ->
          :undefined

        # As in register_name/2: an outage is not "no process"; crash loud.
        {:error, reason} ->
          raise "SessionRegistry.Redis.Via: whereis failed for session " <>
                  "#{inspect(sid)} in #{inspect(handle.owner)}: #{Describe.reason_tag(reason)}"
      end
    end

    def unregister_name({handle, sid}) do
      :ok = Reg.unregister(handle, sid)
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
