defmodule Normandy.ClusterCase do
  @moduledoc """
  Spawns `:peer` nodes that share this node's code paths and config. Use for
  `@moduletag :distributed` tests. Each peer runs the same `:normandy` app code.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Normandy.ClusterCase
    end
  end

  @doc "Start a connected peer node with this node's code paths loaded."
  def start_peer(name) do
    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:horde])
    {pid, node}
  end

  @doc "RPC into a peer."
  def rpc(node, m, f, a), do: :erpc.call(node, m, f, a)

  @doc """
  Start a Horde.Registry on a remote peer node without letting the erpc
  transport process link to the new supervisor.

  `Supervisor.start_link/2` links the calling process to the supervisor. When
  the erpc worker on the peer exits (with its non-`:normal` return envelope),
  the supervisor would receive the EXIT and crash. Unlinking before the erpc
  worker returns prevents that.
  """
  def start_horde_on_peer(node, opts) do
    :erpc.call(node, __MODULE__, :start_horde_unlinked, [opts])
  end

  @doc false
  def start_horde_unlinked(opts) do
    {:ok, pid} = Normandy.Behaviours.SessionRegistry.Horde.start_link(opts)
    Process.unlink(pid)
    {:ok, pid}
  end

  @doc """
  Spawn a long-lived process on `node` that registers itself in `reg` under
  `session_id` and then sleeps. Returns the pid of the spawned process.

  Because `Horde.Registry.register/3` always registers the *calling* process,
  the registration must happen inside the spawned process — we cannot call it
  from an erpc worker and pass a foreign pid.
  """
  def spawn_registered_on_peer(node, reg, session_id) do
    :erpc.call(node, __MODULE__, :do_spawn_registered, [reg, session_id])
  end

  @doc false
  def do_spawn_registered(reg, session_id) do
    parent = self()

    pid =
      spawn(fn ->
        Normandy.Behaviours.SessionRegistry.Horde.register(reg, session_id, self())
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    receive do
      :registered -> pid
    after
      5000 -> raise "do_spawn_registered: timeout waiting for registration"
    end
  end
end
