# Phase 7b — SessionRegistry.Horde + `:via` start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `Normandy.Behaviours.SessionRegistry.Horde` (cluster-wide `session_id → pid` discovery) and a `:via`-based `Turn.Server` start so registration is atomic — which fixes the two deferred follow-ups (foreign-pid registration + the `Turn.Session` rehydrate race). Sessions stay node-pinned under the local supervisor in this phase (registry-only distribution).

**Architecture:** `SessionRegistry.Horde` wraps `Horde.Registry` (`keys: :unique`, `members: :auto`). A new optional behaviour callback `child_name/2` returns either `:self_register` (Native — unchanged) or a `{:via, Horde.Registry, {handle, sid}}` tuple (Horde). `Turn.Server.start_link/1` learns a `:name` option and starts under that via-name; `Turn.Supervisor.start_server/2` computes it; `Turn.Session` treats `{:already_started, pid}` as "route to existing".

**Tech Stack:** Elixir 1.18 / OTP 27, Horde 0.9, `:gen_statem`, `:peer` for multi-node tests.

## Global Constraints

- Elixir floor `~> 1.15`; Erlang 27.2 / Elixir 1.18.1.
- `mix format` before every commit; all tests must pass (fix pre-existing failures too, per `CLAUDE.md`).
- **Default-off:** `SessionRegistry.Native` and its `:self_register` path stay observably unchanged. The all-defaults suite must pass identically.
- Multi-node tests are tagged `@moduletag :distributed` and excluded by default in `test/test_helper.exs`.
- `child_name/2` is an **optional** callback — code that consumes a registry must use `function_exported?/3` and fall back to `:self_register`, so third-party registries without it keep working.
- `git add` files individually. No AI attribution in commits.

## File Structure

- Create `lib/normandy/behaviours/session_registry/horde.ex` — the Horde-backed impl.
- Modify `lib/normandy/behaviours/session_registry.ex` — add the optional `child_name/2` callback + docs.
- Modify `lib/normandy/behaviours/session_registry/native.ex` — implement `child_name/2 → :self_register`.
- Modify `lib/normandy/agents/turn/server.ex:32-33,49-64,266-267` — `:name` option + conditional self-register.
- Modify `lib/normandy/agents/turn/supervisor.ex` — compute the child name from `child_name/2`.
- Modify `lib/normandy/agents/turn/session.ex:44-92` — treat `{:already_started, pid}` as success.
- Create `test/behaviours/session_registry/horde_test.exs` — contract (cluster-of-one).
- Create `test/support/cluster_case.ex` — `:peer` multi-node helper.
- Create `test/agents/turn/horde_distributed_test.exs` — cross-node + race tests.
- Modify `test/test_helper.exs` — exclude `:distributed`.

---

### Task 1: `SessionRegistry.Horde` + contract (cluster-of-one)

**Files:**
- Modify: `mix.exs:135-147`
- Create: `lib/normandy/behaviours/session_registry/horde.ex`
- Create: `test/behaviours/session_registry/horde_test.exs`
- Modify: `test/test_helper.exs`

**Interfaces:**
- Consumes: `Normandy.Behaviours.SessionRegistry` callbacks (`whereis/2`, `register/3`, `unregister/2`); `Normandy.SessionRegistryContract`.
- Produces: `Normandy.Behaviours.SessionRegistry.Horde` with `start_link/1`, `new/1 :: atom()` (the handle), `@behaviour Normandy.Behaviours.SessionRegistry`.

- [ ] **Step 1: Add the horde dependency**

In `mix.exs` `deps/0`, add after `{:ecto_sql, ...}`/`{:postgrex, ...}` (or after `:claudio` if 7a not present):

```elixir
      {:horde, "~> 0.9"},
```

Run: `mix deps.get`
Expected: resolves `horde`, `libring`, `delta_crdt` with no errors.

- [ ] **Step 2: Exclude `:distributed` by default**

In `test/test_helper.exs`, add `:distributed` to the exclude list:

```elixir
ExUnit.start(exclude: [:integration, :normandy_integration, :postgres, :distributed])
```

(If 7a is not yet merged, the list is `[:integration, :normandy_integration, :distributed]`.)

- [ ] **Step 3: Write the failing contract test**

Create `test/behaviours/session_registry/horde_test.exs`:

```elixir
defmodule Normandy.Behaviours.SessionRegistry.HordeTest do
  use ExUnit.Case, async: false
  use Normandy.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Horde
end
```

> NOTE: `async: false` — each test starts its own Horde registry; cluster-of-one means no cross-test interference, but Horde processes are global-ish, so serialize to be safe.

- [ ] **Step 4: Run to verify it fails**

Run: `mix test test/behaviours/session_registry/horde_test.exs`
Expected: FAIL — `Normandy.Behaviours.SessionRegistry.Horde` undefined.

- [ ] **Step 5: Implement `SessionRegistry.Horde`**

Create `lib/normandy/behaviours/session_registry/horde.ex`:

```elixir
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

  @doc "Convenience for tests: start a uniquely-named registry and return its name."
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    name = Keyword.get_lazy(opts, :name, fn -> unique_name() end)
    {:ok, _pid} = start_link(name: name)
    name
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
  @spec child_name(atom(), String.t()) :: {:via, module(), {atom(), String.t()}}
  def child_name(handle, session_id), do: {:via, Horde.Registry, {handle, session_id}}

  defp unique_name do
    String.to_atom("horde_session_registry_" <> Integer.to_string(System.unique_integer([:positive])))
  end
end
```

- [ ] **Step 6: Run the contract to verify it passes**

Run: `mix test test/behaviours/session_registry/horde_test.exs`
Expected: PASS — all 4 contract tests (register/whereis, double-register → `:taken`, unregister frees, dead-process auto-unregister; the last polls via `wait_until` since Horde cleanup is async).

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock lib/normandy/behaviours/session_registry/horde.ex \
  test/behaviours/session_registry/horde_test.exs test/test_helper.exs
git commit -m "feat(session-registry): horde-backed registry passing the registry contract"
```

---

### Task 2: Optional `child_name/2` callback on the behaviour + Native

**Files:**
- Modify: `lib/normandy/behaviours/session_registry.ex`
- Modify: `lib/normandy/behaviours/session_registry/native.ex`
- Test: `test/behaviours/session_registry/native_test.exs`

**Interfaces:**
- Produces: `@callback child_name(handle, session_id) :: {:via, module(), term()} | :self_register` (optional); `Native.child_name/2 → :self_register`; `Horde.child_name/2` already defined in Task 1.

- [ ] **Step 1: Write the failing test**

Add to `test/behaviours/session_registry/native_test.exs`:

```elixir
  test "Native.child_name/2 is :self_register" do
    assert Normandy.Behaviours.SessionRegistry.Native.child_name(:some_handle, "s1") ==
             :self_register
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/behaviours/session_registry/native_test.exs`
Expected: FAIL — `child_name/2` undefined on `Native`.

- [ ] **Step 3: Declare the optional callback on the behaviour**

In `lib/normandy/behaviours/session_registry.ex`, after the three existing `@callback`s, add:

```elixir
  @doc """
  Returns the `name` a `Turn.Server` should start under for atomic registration.

  `:self_register` keeps the historical path (the server calls `register/3` in
  `init`). A `{:via, module, term}` tuple makes the process register at start
  (used by distributed impls), which closes the start-time race. Optional: callers
  fall back to `:self_register` when an impl does not export it.
  """
  @callback child_name(handle(), session_id()) :: {:via, module(), term()} | :self_register
  @optional_callbacks child_name: 2
```

- [ ] **Step 4: Implement `child_name/2` on Native**

In `lib/normandy/behaviours/session_registry/native.ex`, add (after `unregister/2`):

```elixir
  @impl true
  def child_name(_handle, _session_id), do: :self_register
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/behaviours/session_registry/native_test.exs test/behaviours/session_registry/horde_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/behaviours/session_registry.ex \
  lib/normandy/behaviours/session_registry/native.ex \
  test/behaviours/session_registry/native_test.exs
git commit -m "feat(session-registry): optional child_name/2 callback (:self_register | via)"
```

---

### Task 3: `Turn.Server` `:name` option + conditional self-register

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex:32-33,49-64,266-267`
- Test: `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: `child_name/2` (optional) on the configured registry.
- Produces: `Turn.Server.start_link/1` honors `opts[:name]` (a via-tuple) and registers atomically; when `:name` is absent it self-registers via `register/3` (unchanged behavior).

- [ ] **Step 1: Write the failing test**

Add to `test/agents/turn/server_test.exs` (a focused unit test that a via-started server is discoverable without calling `register/3`):

```elixir
  test "starts under a Horde :via name and is discoverable via whereis" do
    reg = Normandy.Behaviours.SessionRegistry.Horde.new()
    sid = "via-#{System.unique_integer([:positive])}"
    name = Normandy.Behaviours.SessionRegistry.Horde.child_name(reg, sid)

    opts = via_server_opts(sid, reg, name)
    assert {:ok, pid} = Normandy.Agents.Turn.Server.start_link(opts)
    assert {:ok, ^pid} = Normandy.Behaviours.SessionRegistry.Horde.whereis(reg, sid)
  end
```

Add a helper in the same test module (reuse the module's existing config builder if present; otherwise):

```elixir
  defp via_server_opts(sid, reg, name) do
    [
      session_id: sid,
      config: build_test_config(),
      store: {Normandy.Behaviours.SessionStore.InMemory, Normandy.Behaviours.SessionStore.InMemory.new()},
      registry: {Normandy.Behaviours.SessionRegistry.Horde, reg},
      name: name
    ]
  end
```

> NOTE: reuse the existing `build_test_config/0` (or equivalent) already used elsewhere in `server_test.exs`; if none exists, copy the minimal config builder from `test/agents/turn/server_integration_test.exs`.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — `start_link/1` ignores `:name`, so `whereis` returns `:none`.

- [ ] **Step 3: Honor `:name` in `start_link/1`**

Replace `start_link/1` (`server.ex:32-33`):

```elixir
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end
```

- [ ] **Step 4: Make `register_self/1` conditional in `init/1`**

Replace `register_self/1` (`server.ex:266-267`):

```elixir
  # When the server was started under a `{:via, _, _}` name, the via callback
  # already registered it; only self-register otherwise.
  defp register_self(%Data{registry: {mod, handle}, session_id: sid}) do
    case child_name_for(mod, handle, sid) do
      :self_register -> mod.register(handle, sid, self())
      {:via, _via_mod, _term} -> :ok
    end
  end

  defp child_name_for(mod, handle, sid) do
    if function_exported?(mod, :child_name, 2),
      do: mod.child_name(handle, sid),
      else: :self_register
  end
```

> NOTE: `init/1` already calls `register_self(data)` at `server.ex:62`; no change there.

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/agents/turn/server_test.exs`
Expected: PASS (new test green; existing Native-based tests unchanged because they pass no `:name` and still self-register).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "feat(turn): Turn.Server :via name option with conditional self-register"
```

---

### Task 4: `Turn.Supervisor` computes the child name; `Turn.Session` race fix

**Files:**
- Modify: `lib/normandy/agents/turn/supervisor.ex`
- Modify: `lib/normandy/agents/turn/session.ex:44-92`
- Test: `test/agents/turn/session_test.exs`, `test/agents/turn/server_integration_test.exs`

**Interfaces:**
- Consumes: `child_name/2` (optional) via the `registry` ref carried in `server_opts`.
- Produces: `Turn.Supervisor.start_server/2` adds `:name` to the child opts when the registry supplies a via-name; `Turn.Session.run/2`/`ensure_server/1` resolve `{:error, {:already_started, pid}}` to `{:ok, pid}`.

- [ ] **Step 1: Write the failing test (race → single winner)**

Add to `test/agents/turn/session_test.exs`:

```elixir
  test "concurrent ensure-server for one session resolves to a single pid (Horde via)" do
    reg = Normandy.Behaviours.SessionRegistry.Horde.new()
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
    sid = "race-#{System.unique_integer([:positive])}"

    opts = [
      session_id: sid,
      config: build_test_config(),
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Horde, reg},
      supervisor: sup
    ]

    pids =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Normandy.Agents.Turn.Session.run(opts, nil) end) end)
      |> Enum.map(&Task.await(&1, 5000))

    # All callers succeed and route to the one registered server.
    assert {:ok, pid} = Normandy.Behaviours.SessionRegistry.Horde.whereis(reg, sid)
    assert Enum.all?(pids, &match?({:ok, _}, &1))
    assert [_one] = Normandy.Agents.Turn.Supervisor |> children_pids(sup) |> Enum.uniq()
    assert is_pid(pid)
  end

  defp children_pids(_mod, sup) do
    DynamicSupervisor.which_children(sup) |> Enum.map(fn {_, p, _, _} -> p end)
  end
```

> NOTE: reuse the test module's existing `build_test_config/0`. `run/2` with `nil` input executes a no-user-input turn against the test config's mock client.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/session_test.exs`
Expected: FAIL — without the via name, two children start (the loser's `register` returns `:taken` but the server keeps running), so `which_children` has >1 pid; or `start_server` returns `{:error, {:already_started, _}}` unhandled.

- [ ] **Step 3: Compute the child name in `start_server/2`**

Replace `Turn.Supervisor.start_server/2`:

```elixir
  @spec start_server(:gen_statem.server_ref() | pid(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_server(sup, server_opts) do
    server_opts = put_child_name(server_opts)

    spec = %{
      id: Server,
      start: {Server, :start_link, [server_opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(sup, spec)
  end

  defp put_child_name(opts) do
    {mod, handle} = Keyword.fetch!(opts, :registry)
    sid = Keyword.fetch!(opts, :session_id)

    name =
      if function_exported?(mod, :child_name, 2),
        do: mod.child_name(handle, sid),
        else: :self_register

    case name do
      :self_register -> opts
      via -> Keyword.put(opts, :name, via)
    end
  end
```

- [ ] **Step 4: Handle `{:already_started, pid}` in `Turn.Session`**

In `lib/normandy/agents/turn/session.ex`, change `rehydrate_and_start/1`'s final `Supervisor.start_server(...)` call (currently `session.ex:87`) to normalize the race result. Replace:

```elixir
        Supervisor.start_server(supervisor, server_opts)
```

with:

```elixir
        case Supervisor.start_server(supervisor, server_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
```

Update the moduledoc race note (`session.ex:44-48`) to state the race is now closed for via-based registries (Horde) and remains best-effort for `:self_register` (Native).

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/agents/turn/session_test.exs`
Expected: PASS — exactly one child pid; all 10 callers get `{:ok, _}`.

- [ ] **Step 6: Update + run affected integration tests (back-compat)**

The Native (default) path must be unchanged. Run the existing Turn integration + config suites:

Run: `mix test test/agents/turn/server_integration_test.exs test/agents/turn/session_test.exs test/coordination/agent_process_server_test.exs test/behaviours/config_test.exs`
Expected: PASS. If any assertion depended on the prior `register_self` ordering, update it to assert via `whereis` instead (the public discovery path), not internal ordering.

- [ ] **Step 7: Run the full default suite**

Run: `mix format && mix test`
Expected: PASS — defaults (`Native`/`InMemory`) identical to before; `:postgres`/`:distributed` excluded.

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/agents/turn/supervisor.ex lib/normandy/agents/turn/session.ex \
  test/agents/turn/session_test.exs
git commit -m "feat(turn): atomic via-registration via supervisor child_name; close rehydrate race"
```

---

### Task 5: Multi-node `:distributed` tests (`:peer`)

**Files:**
- Create: `test/support/cluster_case.ex`
- Create: `test/agents/turn/horde_distributed_test.exs`

**Interfaces:**
- Consumes: `SessionRegistry.Horde`, `:peer` (OTP 27).
- Produces: `Normandy.ClusterCase` with `start_peer/1` and `rpc/4` helpers.

- [ ] **Step 1: Write the cluster helper**

Create `test/support/cluster_case.ex`:

```elixir
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

    :ok = :peer.call(pid, :code, :add_paths, [:code.get_path()])
    :peer.call(pid, Application, :ensure_all_started, [:horde])
    {pid, node}
  end

  @doc "RPC into a peer."
  def rpc(node, m, f, a), do: :erpc.call(node, m, f, a)
end
```

> NOTE: this node must be distributed for `:peer` to connect. The test ensures it via `:net_kernel.start/1` if `Node.self() == :nonode@nohost` (Step 2).

- [ ] **Step 2: Write the failing cross-node + race tests**

Create `test/agents/turn/horde_distributed_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.HordeDistributedTest do
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed

  alias Normandy.Behaviours.SessionRegistry.Horde

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    end

    :ok
  end

  test "a session registered on a peer is discoverable from this node" do
    reg = :"dist_reg_#{System.unique_integer([:positive])}"
    {:ok, _} = Horde.start_link(name: reg)
    {peer, node} = start_peer(~c"peer1")
    {:ok, _} = rpc(node, Horde, :start_link, [[name: reg]])

    # Let :auto membership converge after node connect.
    Process.sleep(500)

    sid = "cross-#{System.unique_integer([:positive])}"
    remote = rpc(node, Kernel, :spawn, [fn -> Process.sleep(60_000) end])
    :ok = rpc(node, Horde, :register, [reg, sid, remote])

    assert eventually(fn -> match?({:ok, ^remote}, Horde.whereis(reg, sid)) end)

    :peer.stop(peer)
  end

  test "double registration cluster-wide yields a single winner" do
    reg = :"dist_reg_#{System.unique_integer([:positive])}"
    {:ok, _} = Horde.start_link(name: reg)
    {peer, node} = start_peer(~c"peer2")
    {:ok, _} = rpc(node, Horde, :start_link, [[name: reg]])
    Process.sleep(500)

    sid = "dup-#{System.unique_integer([:positive])}"
    assert :ok = Horde.register(reg, sid, self())
    assert {:error, :taken} = rpc(node, Horde, :register, [reg, sid, self()])

    :peer.stop(peer)
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20); eventually(fun, retries - 1)
    end
  end
end
```

- [ ] **Step 3: Run the distributed tests**

Run: `mix test test/agents/turn/horde_distributed_test.exs --include distributed`
Expected: PASS — cross-node `whereis` resolves the peer's pid; the second cluster-wide registration is rejected. (If `:auto` membership has not converged, increase the `Process.sleep` after connect; flagged as a tuning point.)

- [ ] **Step 4: Confirm default suite still excludes them**

Run: `mix test`
Expected: PASS — `:distributed` excluded; no peer nodes started.

- [ ] **Step 5: Commit**

```bash
git add test/support/cluster_case.ex test/agents/turn/horde_distributed_test.exs
git commit -m "test(turn): multi-node horde registry cross-node + single-winner tests"
```

---

## Self-Review

- **Spec coverage (§7.1, §7.2):** Horde impl over `Horde.Registry` `members: :auto` (Task 1); contract verbatim cluster-of-one (Task 1); optional `child_name/2` (Task 2); `Native.child_name → :self_register` unchanged (Task 2); `:via` start on `Turn.Server` (Task 3); supervisor computes the name + race closed via `{:already_started, pid}` (Task 4); foreign-pid documented as unsupported (Task 1 `register/3` clause); multi-node tests via `:peer` (Task 5); integration/back-compat run (Task 4 Step 6–7). ✓
- **Integration tests:** Task 4 Step 6 explicitly re-runs and (if needed) updates `server_integration_test.exs`, `agent_process_server_test.exs`, `config_test.exs`; assertions on internal registration ordering switch to `whereis`.
- **Deferred (intentional):** Horde **DynamicSupervisor** placement and template reconstruction are Phase 7c (this phase keeps the local supervisor → direct config, no gossiped specs).
- **Placeholder scan:** none — complete code per step. The only soft spot is `:auto`-membership convergence timing in Task 5 (flagged with a tuning note, not a placeholder).
- **Type consistency:** `child_name/2` returns `{:via, module, term} | :self_register` everywhere; `Horde.whereis/register/unregister` mirror the Native return shapes (`{:ok, pid} | :none`, `:ok | {:error, :taken}`, `:ok`); `start_server/2` still returns `DynamicSupervisor.on_start_child()`.
