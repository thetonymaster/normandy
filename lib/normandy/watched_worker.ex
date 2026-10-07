defmodule Normandy.WatchedWorker do
  @moduledoc false
  # Runs `work` in a process that never outlives its owner (the caller of `start/2`).
  #
  # `start/2` spawns a monitored, unlinked watcher and returns `{watcher, monitor_ref}`.
  # The watcher monitors the owner, traps exits and runs `work` in a linked worker:
  #
  #   * `work` returns `result`: the owner gets `{tag, watcher, result}`, then the
  #     watcher's `:DOWN` with reason `:normal` (demonitor it with `:flush`).
  #   * the worker dies (raised, exited, threw, was killed): the watcher exits with the
  #     worker's reason, which the owner sees as the watcher's `:DOWN`.
  #   * the owner dies: the worker is killed, so no turn runs on unseen.
  #
  # The owner keys the work by the watcher pid, so there is no monitor-ref handshake.
  #
  # Both processes get `$callers` as `Task` sets it (the watcher `[owner | owner's
  # callers]`, the worker `[watcher | ...]`), so ownership-based test tools (Mox,
  # `Req.Test`, Ecto's sandbox) find the owner's allowances from inside `work`.
  # Turn.Server's run_while_server_alive/3 has the same shape; it is meant to move here.

  @spec start(term(), (-> term())) :: {pid(), reference()}
  def start(tag, work) when is_function(work, 0) do
    owner = self()
    callers = [owner | Process.get(:"$callers", [])]
    spawn_monitor(fn -> watch(owner, callers, tag, work) end)
  end

  defp watch(owner, callers, tag, work) do
    Process.put(:"$callers", callers)
    owner_ref = Process.monitor(owner)
    Process.flag(:trap_exit, true)
    watcher = self()

    worker =
      spawn_link(fn ->
        Process.put(:"$callers", [watcher | callers])
        send(watcher, {__MODULE__, work.()})
      end)

    receive do
      {__MODULE__, result} -> send(owner, {tag, watcher, result})
      {:EXIT, ^worker, reason} -> exit(reason)
      {:DOWN, ^owner_ref, :process, _pid, _reason} -> Process.exit(worker, :kill)
    end
  end
end
