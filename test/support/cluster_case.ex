defmodule Normandy.ClusterCase do
  @moduledoc """
  Spawns `:peer` nodes that share this node's code paths and config. Use for
  `@moduletag :distributed` tests. Each peer runs the same `:normandy` app code.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Normandy.ClusterCase
      # Shared eventually-consistent polling helper for distributed assertions.
      import Normandy.Test.Eventually
    end
  end

  @doc "A named initial-state function for `Agent.start_link/3` that works across nodes."
  def agent_initial_state, do: :idle

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
  Start a `Horde.DynamicSupervisor` on a remote peer node without letting the
  erpc transport process link to it.

  Same unlinking technique as `start_horde_on_peer/2` but for
  `Horde.DynamicSupervisor` rather than `Normandy.Behaviours.SessionRegistry.Horde`.
  """
  def start_horde_dsup_on_peer(node, name) do
    :erpc.call(node, __MODULE__, :start_horde_dsup_unlinked, [name])
  end

  @doc false
  def start_horde_dsup_unlinked(name) do
    {:ok, pid} =
      Horde.DynamicSupervisor.start_link(name: name, strategy: :one_for_one, members: :auto)

    Process.unlink(pid)
    {:ok, pid}
  end

  @doc """
  Start a child directly in `Horde.ProcessesSupervisor` on a peer node, bypassing
  Horde's distribution-strategy placement. This guarantees the process lands on the
  peer regardless of consistent-hashing outcomes.

  The child spec must use a named function (not a closure) for its `start` MFA so
  it can be serialised and called on the remote node.
  """
  def start_child_on_peer(node, horde_dsup_name, child_spec) do
    :erpc.call(node, __MODULE__, :do_start_child_direct, [horde_dsup_name, child_spec])
  end

  @doc false
  def do_start_child_direct(horde_dsup_name, child_spec) do
    processes_sup = :"#{horde_dsup_name}.ProcessesSupervisor"
    Horde.ProcessesSupervisor.start_child(processes_sup, child_spec)
  end

  @doc """
  Start `Normandy.TestRepo` on a peer node without linking it to the erpc
  transport worker. Pass explicit `repo_opts` (from the primary's application env)
  so the peer does not need Mix or compiled config available.

  Used in `:postgres` + `:distributed` tests to give the peer node database
  access for thin-config reconstruction.
  """
  def start_test_repo_on_peer(node, repo_opts) do
    :erpc.call(node, __MODULE__, :start_test_repo_unlinked, [repo_opts])
  end

  @doc false
  def start_test_repo_unlinked(repo_opts) do
    # Ensure ecto_sql and postgrex are started on the peer.
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)

    # Write the repo config into the application env on the peer node so the
    # Repo process can find its connection parameters at startup.
    Application.put_env(:normandy, Normandy.TestRepo, repo_opts)
    Application.put_env(:normandy, :ecto_repos, [Normandy.TestRepo])

    # Start with pool_size: 1 and the Sandbox pool in :auto mode (set below): spawned
    # processes get implicit checkouts, so cross-node writes are visible without an
    # explicit checkout on this peer.
    clean_opts = Keyword.merge(repo_opts, pool_size: 1, pool: Ecto.Adapters.SQL.Sandbox)

    {:ok, pid} = Normandy.TestRepo.start_link(clean_opts)
    Process.unlink(pid)
    Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, :auto)
    {:ok, pid}
  rescue
    e -> {:error, Exception.message(e)}
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

  # --- Redis registry helpers (compiled into the ebin path so peers can call them) ---

  @doc """
  Start a `Normandy.Behaviours.SessionRegistry.Redis` owner on a remote peer node
  without letting the erpc transport worker link to it (same unlinking pattern as
  `start_horde_on_peer/2`).
  """
  def start_redis_on_peer(node, opts) do
    :rpc.call(node, __MODULE__, :start_redis_unlinked, [opts])
  end

  @doc false
  def start_redis_unlinked(opts) do
    {:ok, pid} = Normandy.Behaviours.SessionRegistry.Redis.start_link(opts)
    Process.unlink(pid)
    {:ok, pid}
  end

  @doc """
  Spawn a long-lived process on `node` that registers itself in the Redis registry
  `reg_name` under `session_id` and then sleeps. Returns the remote pid.

  Mirrors `do_spawn_registered/2` but for the Redis backend.
  """
  def spawn_redis_registered_on_peer(node, reg_name, session_id) do
    :rpc.call(node, __MODULE__, :do_spawn_redis_registered, [reg_name, session_id])
  end

  @doc false
  def do_spawn_redis_registered(reg_name, session_id) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = Normandy.Behaviours.SessionRegistry.Redis.register(reg_name, session_id, self())
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    receive do
      :registered -> pid
    after
      5000 ->
        raise "do_spawn_redis_registered: timeout waiting for registration on #{inspect(reg_name)}"
    end
  end
end
