# Phase 7d — Eager Handoff / Auto-Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For sessions flagged `resume_policy: :eager`, a `Turn.Server` that dies with its node is redistributed by `Horde.DynamicSupervisor` to a surviving node and **auto-resumes the in-flight turn** from the last durable boundary — with no inbound request. For autonomous/long-running agents.

**Architecture:** Make the turn durable at each `:steering` (tool-batch) boundary by emitting `{:persist, s2}` there (today only the approval suspend point persists). Add a pure `Turn.resume/1` that re-derives the effects to continue from a persisted non-terminal state. `Turn.Server.init/1` loads the latest turn state from the store and, when `resume_policy == :eager` and the state is non-terminal, kicks an internal `:resume` event instead of idling. `:eager` maps to `restart: :transient` (7c), so Horde redistributes the child on node-down.

**Tech Stack:** Elixir 1.18 / OTP 27, Horde 0.9, `:gen_statem`, pure `Turn` FSM core.

## Global Constraints

- Elixir floor `~> 1.15`; Erlang 27.2 / Elixir 1.18.1.
- `mix format` before every commit; all tests pass (fix pre-existing failures too).
- **Default-off:** `resume_policy` defaults to `:lazy`; lazy + inline behavior is observably unchanged except for the (cheap, idempotent) extra `:steering` persist, which the inline `Turn.Driver` treats as a no-op.
- **Dual-interpreter rule** ([[turn-server-separate-interpreter]]): the new `{:persist, _}` emission at `:steering` reaches BOTH `Turn.Driver` (inline) and `Turn.Server`. `Turn.Driver` must gain a no-op `{:persist, _}` clause or it will crash.
- **Hard invariant (unchanged):** no caller is present on eager resume, so `pending_reply` is `nil` and `reply/2` is a no-op; the turn runs to completion persisting along the way; credentials/config come from the node-local reconstruction (7c).
- Depends on **7a/7b/7c**.
- Multi-node tests `@moduletag :distributed`; excluded by default.
- `git add` individually; no AI attribution.

## File Structure

- Modify `lib/normandy/agents/turn.ex:266-281` — emit `{:persist, s2}` at the `:steering` boundary; add `resume/1`.
- Modify `lib/normandy/agents/turn/driver.ex` — no-op `{:persist, _}` clause.
- Modify `lib/normandy/agents/turn/server.ex` — load turn state from store on reconstruct; eager `:resume` internal event.
- Modify `lib/normandy/agents/config_template.ex` — carry `resume_policy` in the template.
- Create `test/agents/turn/resume_test.exs` — `Turn.resume/1` unit tests.
- Modify `test/agents/turn/driver_test.exs` — assert the no-op persist.
- Create `test/agents/turn/eager_resume_test.exs` — server-level eager init resume.
- Create `test/agents/turn/eager_handoff_distributed_test.exs` — node-down → auto-resume on survivor.
- Create `lib/normandy/cluster.ex` — optional `Normandy.Cluster` helper.
- Create `docs/guides/distributed_sessions.md` — libcluster topology + supervision example.
- Modify `mix.exs` — add `{:libcluster, "~> 3.4", optional: true}` and the guide to `docs.extras`.

---

### Task 1: Persist at the `:steering` boundary (core) + `Turn.Driver` no-op

**Files:**
- Modify: `lib/normandy/agents/turn.ex:266-281`
- Modify: `lib/normandy/agents/turn/driver.ex`
- Test: `test/agents/turn/turn_test.exs` (or wherever `step/2` is tested), `test/agents/turn/driver_test.exs`

**Interfaces:**
- Produces: `apply_tool_results/2` now appends a `{:persist, s2}` effect at the steering boundary; `Turn.Driver` interprets `{:persist, _}` as a no-op.

- [ ] **Step 1: Write the failing core test**

In the `Turn` core test file, add a test asserting the steering boundary emits a persist of the new `:steering` state:

```elixir
  test "a completed tool batch persists the steering state before compaction" do
    s = %Normandy.Agents.Turn.State{status: :tool_dispatch, iterations_left: 3, max_iterations: 5,
                                    pending_calls: []}
    {s2, effects} = Normandy.Agents.Turn.step(s, {:tool_results, []})

    assert s2.status == :steering
    assert Enum.any?(effects, &match?({:persist, %Normandy.Agents.Turn.State{status: :steering}}, &1))
    # persist comes before maybe_compact
    persist_idx = Enum.find_index(effects, &match?({:persist, _}, &1))
    compact_idx = Enum.find_index(effects, &match?({:maybe_compact, _}, &1))
    assert persist_idx < compact_idx
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/turn_test.exs`
Expected: FAIL — no `{:persist, _}` effect at the steering boundary today.

- [ ] **Step 3: Emit the persist in `apply_tool_results/2`**

In `lib/normandy/agents/turn.ex`, change the effect list returned by `apply_tool_results/2` (currently `turn.ex:280`):

```elixir
    {s2, append_effects ++ [steering, {:persist, s2}, {:maybe_compact, %{iterations_left: new_left}}]}
```

- [ ] **Step 4: Add the `Turn.Driver` no-op persist clause**

In `lib/normandy/agents/turn/driver.ex`, find the effect interpreter (the `case effect do` / function-head dispatch over effects) and add a clause that ignores persist — the inline path has no store:

```elixir
      {:persist, _turn_state} ->
        # Inline driver has no SessionStore/passivation; persistence is a no-op.
        interpret(rest, data)
```

> NOTE: match the exact interpreter shape in `driver.ex` (it mirrors `server.ex`'s `interpret/2`). If the driver uses a different accumulator name than `data`/`rest`, adapt the clause to that shape. The point: consume `{:persist, _}` without doing I/O and continue.

- [ ] **Step 5: Run core + driver tests**

Run: `mix test test/agents/turn/turn_test.exs test/agents/turn/driver_test.exs`
Expected: PASS. If a driver test asserted an exact effect-free run, update it to tolerate/ignore `{:persist, _}` (the inline result is unchanged).

- [ ] **Step 6: Run the full default suite**

Run: `mix format && mix test`
Expected: PASS — `Turn.Server` already handles `{:persist, _}` (`server.ex:178`), so the only new consumer is the driver no-op.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/turn.ex lib/normandy/agents/turn/driver.ex \
  test/agents/turn/turn_test.exs test/agents/turn/driver_test.exs
git commit -m "feat(turn): persist turn state at the steering boundary; driver no-ops persist"
```

---

### Task 2: `Turn.resume/1` (pure)

**Files:**
- Modify: `lib/normandy/agents/turn.ex`
- Test: `test/agents/turn/resume_test.exs`

**Interfaces:**
- Produces: `Turn.resume(State.t()) :: {State.t(), [tuple()]}` — given a persisted non-terminal state, returns the effects to continue:
  - `:steering` → re-issue `{:maybe_compact, %{iterations_left: left}}` (then the existing `:compaction_done` clauses continue or force-final).
  - `:awaiting_approval` → `{state, []}` (no auto-resume; the shell re-arms the approval timeout and waits for `{:approval, _}`).
  - `:stopped` / `:failed` → `{state, []}` (terminal).

- [ ] **Step 1: Write the failing tests**

Create `test/agents/turn/resume_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ResumeTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State

  test "resume from :steering re-issues maybe_compact" do
    s = %State{status: :steering, iterations_left: 2, max_iterations: 5}
    assert {^s, [{:maybe_compact, %{iterations_left: 2}}]} = Turn.resume(s)
  end

  test "resume from :awaiting_approval emits no effects (waits for approval)" do
    s = %State{status: :awaiting_approval, parked_calls: [:c], iterations_left: 1, max_iterations: 5}
    assert {^s, []} = Turn.resume(s)
  end

  test "resume from a terminal state is a no-op" do
    for status <- [:stopped, :failed] do
      s = %State{status: status}
      assert {^s, []} = Turn.resume(s)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/resume_test.exs`
Expected: FAIL — `Turn.resume/1` undefined.

- [ ] **Step 3: Implement `resume/1`**

In `lib/normandy/agents/turn.ex`, add after `step/2` (before the private helpers):

```elixir
  @doc """
  Re-derives the effects to continue a turn from a **persisted, non-terminal**
  state (used by an eager shell after passivation/handoff). Pure.

  Only states the core persists are resumable: `:steering` (per-batch boundary)
  re-issues compaction then continues; `:awaiting_approval` waits for a decision
  (no effects). Terminal states yield no effects.
  """
  @spec resume(State.t()) :: {State.t(), [tuple()]}
  def resume(%State{status: :steering, iterations_left: left} = s) do
    {s, [{:maybe_compact, %{iterations_left: left}}]}
  end

  def resume(%State{status: :awaiting_approval} = s), do: {s, []}
  def resume(%State{status: status} = s) when status in [:stopped, :failed], do: {s, []}

  # Any other persisted status is not a durable resume point; surface as failed so
  # an eager shell does not silently hang on an unresumable state.
  def resume(%State{} = s) do
    reason = {:unresumable_state, s.status}
    {%{s | status: :failed, error: reason}, [{:fail, reason}]}
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/agents/turn/resume_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn.ex test/agents/turn/resume_test.exs
git commit -m "feat(turn): pure Turn.resume/1 for eager continuation from a persisted state"
```

---

### Task 3: `Turn.Server` eager init resume + load turn state from store

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (init reconstruct path from 7c; add `:resume` handling)
- Modify: `lib/normandy/agents/config_template.ex`
- Test: `test/agents/turn/eager_resume_test.exs`

**Interfaces:**
- Consumes: `Turn.resume/1`, `SessionStore.load_turn_state/2`, `Data.resume_policy` (added in 7c).
- Produces: when reconstructing (Tier-2, no `:config`), `init/1` loads the latest turn state from the store; when `resume_policy == :eager` and that state is non-terminal, `init/1` schedules an internal `:resume` event that drives the turn to completion without a caller. `ConfigTemplate.from_config/2` carries `resume_policy`; `rebuild/3` is unaffected (resume_policy is read from the template by the server, not placed on the config).

- [ ] **Step 1: Write the failing test**

Create `test/agents/turn/eager_resume_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.EagerResumeTest do
  @moduledoc "Eager auto-resume on (re)start from a persisted :steering state, no caller."
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.AgentTemplate.Catalog

  test "eager server with a persisted :steering state resumes to completion without a caller" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])
    sid = "eager-#{System.unique_integer([:positive])}"

    base = Normandy.Test.TurnConfig.build()

    tmpl =
      base
      |> Normandy.Agents.ConfigTemplate.from_config("k", :eager)
      |> put_in([:behaviours_refs, :credential], {Normandy.Test.StubCreds, []})

    :ok = InMemory.save_config_template(store, sid, tmpl)
    :ok = Catalog.put(cat, "k", %{tool_registry: base.tool_registry, before_hooks: [],
                                   after_hooks: [], client_builder: fn _ -> base.client end})

    # Seed a non-terminal persisted turn state at a steering boundary.
    steering = %Turn.State{status: :steering, iterations_left: 1, max_iterations: 5}
    :ok = InMemory.save_turn_state(store, sid, steering)

    opts = [
      session_id: sid,
      store: {InMemory, store},
      registry: {Native, reg},
      template_provider: {Catalog, cat},
      resume_policy: :eager
    ]

    assert {:ok, pid} = Turn.Server.start_link(opts)
    ref = Process.monitor(pid)
    # The resumed turn runs maybe_compact → next LLM call (forced-final at left<=0)
    # → finalize → :idle. It must not crash; eventually it idles or passivates.
    refute_receive {:DOWN, ^ref, :process, ^pid, reason} when reason not in [:normal], 2_000
    assert {:ok, ^pid} = Native.whereis(reg, sid)
  end
end
```

> NOTE: `ConfigTemplate.from_config/3` (Task 3 Step 3) sets `resume_policy: :eager`; the `put_in/3` overrides the credential ref to the node-local `Normandy.Test.StubCreds` (defined in 7c) so reconstruction resolves a token without a live client. `Normandy.Test.TurnConfig.build/0` is the shared test config extracted in 7c.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/eager_resume_test.exs`
Expected: FAIL — `init/1` ignores `resume_policy`/persisted turn state and goes straight to `:idle`.

- [ ] **Step 3: Carry `resume_policy` in the template**

In `lib/normandy/agents/config_template.ex`, add to the `from_config/2` map:

```elixir
      resume_policy: :lazy,
```

and accept an optional override by adding a 3-arity:

```elixir
  @spec from_config(BaseAgentConfig.t(), String.t(), :lazy | :eager) :: map()
  def from_config(%BaseAgentConfig{} = c, template_id, resume_policy) do
    from_config(c, template_id) |> Map.put(:resume_policy, resume_policy)
  end
```

- [ ] **Step 4: Load turn state from store on reconstruct; schedule eager resume**

In `lib/normandy/agents/turn/server.ex`, in the `init/1` reconstruct path (7c), after building `config` and BEFORE building `Data`, load the latest turn state from the store when reconstructing (so a Horde-redistributed server gets the durable state, not the stale spec value):

```elixir
    turn_state =
      case Keyword.fetch(opts, :turn_state) do
        {:ok, ts} when not is_nil(ts) -> ts
        _ -> load_turn_state(store, session_id)
      end

    resume_policy =
      case Keyword.get(opts, :config) do
        nil -> template_resume_policy(store, session_id, Keyword.get(opts, :resume_policy, :lazy))
        _ -> Keyword.get(opts, :resume_policy, :lazy)
      end
```

Set `turn_state: turn_state` and `resume_policy: resume_policy` in the `Data` struct (replacing the prior `turn_state`/`resume_policy` assignments). Then replace the `init/1` return:

```elixir
    register_self(data)

    if data.resume_policy == :eager and resumable?(data.turn_state) do
      {:ok, :idle, data, [{:next_event, :internal, :resume}]}
    else
      {:ok, :idle, data, idle_timeout(data)}
    end
  end

  defp load_turn_state({mod, handle}, sid) do
    case mod.load_turn_state(handle, sid) do
      {:ok, ts} -> ts
      :error -> nil
    end
  end

  defp template_resume_policy({mod, handle}, sid, default) do
    case mod.load_config_template(handle, sid) do
      {:ok, %{resume_policy: rp}} -> rp
      _ -> default
    end
  end

  defp resumable?(%Turn.State{status: status}) when status not in [:stopped, :failed], do: true
  defp resumable?(_), do: false
```

Add the internal `:resume` handler near the other `:idle` clauses:

```elixir
  # Eager auto-resume: drive the persisted in-flight turn to completion. No caller
  # is waiting (pending_reply is nil → reply/2 is a no-op), so the turn finalizes
  # silently while persisting at each boundary.
  def handle_event(:internal, :resume, :idle, data) do
    {state, effects} = Turn.resume(data.turn_state)
    interpret(effects, %{data | turn_state: state})
  end
```

> NOTE: `interpret/2` returns proper `:gen_statem` transitions (e.g. `{:next_state, :running, ...}`), so kicking it via `{:next_event, :internal, :resume}` from `:idle` is valid. The `idle_timeout` is intentionally omitted in the eager-resumable branch — the internal event fires before any timeout and moves the machine to `:running`.

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/agents/turn/eager_resume_test.exs`
Expected: PASS — the resumed turn runs to completion (the test's mock client returns a final response), the server does not crash, and stays registered.

- [ ] **Step 6: Run the default suite (lazy unchanged)**

Run: `mix format && mix test`
Expected: PASS — lazy sessions (`resume_policy: :lazy`, the default) never schedule `:resume`; behavior unchanged.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/agents/config_template.ex \
  test/agents/turn/eager_resume_test.exs
git commit -m "feat(turn): eager auto-resume on init from persisted turn state"
```

---

### Task 4: `:distributed` eager-handoff test + verify Horde redistribution

**Files:**
- Create: `test/agents/turn/eager_handoff_distributed_test.exs`

**Interfaces:**
- Consumes: `Normandy.ClusterCase` (7b), `Turn.Supervisor.Horde` (7c), `SessionRegistry.Horde`, a Postgres store reachable from both nodes (the durable source of turn state + template).

- [ ] **Step 1: Verify the load-bearing Horde assumption first (design §7.6 open question)**

Write a focused distributed test that confirms `Horde.DynamicSupervisor` **redistributes a `:transient` child on node-down** but **does not redistribute a `:temporary` child**:

```elixir
defmodule Normandy.Agents.Turn.HordeRedistributionTest do
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed

  setup_all do
    unless Node.alive?(), do: {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    :ok
  end

  test ":transient child is redistributed on node-down; :temporary is not" do
    sup = :"redist_#{System.unique_integer([:positive])}"
    {:ok, _} = Horde.DynamicSupervisor.start_link(name: sup, strategy: :one_for_one, members: :auto)
    {peer, node} = start_peer(~c"redistpeer")
    {:ok, _} = rpc(node, Horde.DynamicSupervisor, :start_link,
                   [[name: sup, strategy: :one_for_one, members: :auto]])
    Process.sleep(500)

    transient = %{id: :t, start: {Agent, :start_link, [fn -> :ok end]}, restart: :transient}
    temporary = %{id: :p, start: {Agent, :start_link, [fn -> :ok end]}, restart: :temporary}

    # Start both children pinned on the peer node.
    {:ok, _} = rpc(node, Horde.DynamicSupervisor, :start_child, [sup, transient])
    {:ok, _} = rpc(node, Horde.DynamicSupervisor, :start_child, [sup, temporary])
    Process.sleep(300)

    :peer.stop(peer)

    # After the peer leaves, the transient child is restarted on this node; the
    # temporary child is gone.
    assert eventually(fn -> child_present?(sup, :t) end)
    refute child_present?(sup, :p)
  end

  defp child_present?(sup, id) do
    Horde.DynamicSupervisor.which_children(sup)
    |> Enum.any?(fn {cid, _, _, _} -> cid == id end)
  rescue
    _ -> false
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20); eventually(fun, retries - 1)
    end
  end
end
```

> NOTE: this directly tests the assumption flagged in design §7.6. If Horde does **not** honor `:temporary` (i.e., it redistributes everything), STOP and revisit: lazy/eager selectivity must then use two separate Horde supervisors (one redistributing, one not) instead of the `restart` value. Record the outcome in the design's "Open questions" section.

- [ ] **Step 2: Write the end-to-end eager-handoff test**

Create `test/agents/turn/eager_handoff_distributed_test.exs`. Start a session as `:eager` on the peer (under `Turn.Supervisor.Horde`), with a Postgres store reachable from both nodes; seed a `:steering` turn state; kill the peer; assert the session reappears (auto-resumed) on the primary and the conversation advances in Postgres.

```elixir
defmodule Normandy.Agents.Turn.EagerHandoffDistributedTest do
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed
  @moduletag :postgres

  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  setup_all do
    unless Node.alive?(), do: {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  test "an eager session on a dying node auto-resumes on a survivor" do
    # Build registry + Horde supervisor on both nodes; register the AgentTemplate
    # supplement on both (same code path). Persist template (:eager) + a :steering
    # turn state in Postgres. Start the session pinned on the peer. Kill the peer.
    # Assert: HReg.whereis resolves to a pid on the primary within a few seconds,
    # and the persisted turn state advances past :steering (or reaches :stopped).
    #
    # Full wiring mirrors tier2_integration_test.exs but with:
    #   store: {Normandy.Behaviours.SessionStore.Postgres, Normandy.TestRepo}
    #   supervisor_mod: Normandy.Agents.Turn.Supervisor.Horde
    #   resume_policy: :eager
    flunk("implement against the running primary+peer+Postgres harness")
  end
end
```

> NOTE: this is the only test in the plan that requires BOTH a peer node AND Postgres; it runs in the combined CI job (`--include distributed --include postgres`). Replace the `flunk/1` with the concrete harness following `tier2_integration_test.exs` + `HordeRedistributionTest` patterns; the `flunk` is a deliberate red so the task is not marked done until the harness exists.

- [ ] **Step 3: Run the redistribution test**

Run: `mix test test/agents/turn/eager_handoff_distributed_test.exs test/agents/turn/horde_redistribution_test.exs --include distributed --include postgres`
Expected: the redistribution test PASSES (confirming the `:transient`/`:temporary` assumption); the end-to-end test PASSES once implemented.

- [ ] **Step 4: Confirm default suite excludes them**

Run: `mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/agents/turn/eager_handoff_distributed_test.exs test/agents/turn/horde_redistribution_test.exs
git commit -m "test(turn): verify horde redistribution + eager auto-resume across nodes"
```

---

### Task 5: Optional `Normandy.Cluster` helper + libcluster example docs

**Files:**
- Modify: `mix.exs:135-147` (deps), `mix.exs:26-34` (docs extras)
- Create: `lib/normandy/cluster.ex`
- Create: `docs/guides/distributed_sessions.md`
- Test: `test/cluster_test.exs`

**Interfaces:**
- Produces: `Normandy.Cluster.child_specs/1 :: [Supervisor.child_spec()]` returning the Horde registry + Horde supervisor (+ optional libcluster) specs for the host to drop into its supervision tree.

- [ ] **Step 1: Add libcluster as an optional dependency**

In `mix.exs` `deps/0`, add:

```elixir
      {:libcluster, "~> 3.4", optional: true},
```

Run: `mix deps.get`
Expected: resolves; `libcluster` is optional (not started unless the host depends on it).

- [ ] **Step 2: Write the failing test**

Create `test/cluster_test.exs`:

```elixir
defmodule Normandy.ClusterTest do
  use ExUnit.Case, async: true

  test "child_specs returns horde registry + supervisor specs" do
    specs = Normandy.Cluster.child_specs(registry: :my_reg, supervisor: :my_sup)
    ids = Enum.map(specs, & &1.id)
    assert :my_reg in ids
    assert :my_sup in ids
  end

  test "child_specs omits libcluster when no topologies given" do
    specs = Normandy.Cluster.child_specs(registry: :r, supervisor: :s)
    refute Enum.any?(specs, &(&1.id == Cluster.Supervisor))
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/cluster_test.exs`
Expected: FAIL — `Normandy.Cluster` undefined.

- [ ] **Step 4: Implement `Normandy.Cluster`**

Create `lib/normandy/cluster.ex`:

```elixir
defmodule Normandy.Cluster do
  @moduledoc """
  Optional convenience for wiring the distributed session infra into a host
  supervision tree. Returns child specs for the Horde registry + Horde supervisor
  (both `members: :auto`), and — if `:topologies` is given and `libcluster` is a
  dependency — a `Cluster.Supervisor` to connect nodes. Cluster formation remains
  the host's choice; this is sugar, not a requirement.

      children = Normandy.Cluster.child_specs(
        registry: MyApp.SessionRegistry,
        supervisor: MyApp.TurnSupervisor,
        topologies: Application.get_env(:libcluster, :topologies, [])
      )
  """
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  @spec child_specs(keyword()) :: [:supervisor.child_spec() | map()]
  def child_specs(opts) do
    reg = Keyword.fetch!(opts, :registry)
    sup = Keyword.fetch!(opts, :supervisor)
    topologies = Keyword.get(opts, :topologies, [])

    cluster =
      if topologies != [] and Code.ensure_loaded?(Cluster.Supervisor) do
        [{Cluster.Supervisor, [topologies, [name: Module.concat(reg, ClusterSupervisor)]]}]
      else
        []
      end

    cluster ++
      [
        %{id: reg, start: {HReg, :start_link, [[name: reg]]}},
        %{id: sup, start: {HSup, :start_link, [[name: sup]]}}
      ]
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/cluster_test.exs`
Expected: PASS.

- [ ] **Step 6: Write the guide**

Create `docs/guides/distributed_sessions.md` covering: the three tiers; a host `application.ex` snippet starting `Normandy.Cluster.child_specs/1` + the host Repo + the `AgentTemplate.Catalog` (with supplement registration); a libcluster `topologies` example (e.g. `Cluster.Strategy.Gossip` and a k8s DNS strategy); the env/vault `CredentialProvider` requirement for eager handoff; and the `resume_policy: :eager` opt-in. Reference `docs/superpowers/specs/2026-06-17-phase-7-distributed-sessions-design.md`.

- [ ] **Step 7: Add the guide to ExDoc extras**

In `mix.exs` `docs: [extras: [...]]` (`mix.exs:26-34`), add `"docs/guides/distributed_sessions.md"`.

- [ ] **Step 8: Run docs + full suite**

Run: `mix docs` (no warnings for the new guide) and `mix format && mix test`
Expected: docs build; suite green.

- [ ] **Step 9: Commit**

```bash
git add mix.exs mix.lock lib/normandy/cluster.ex docs/guides/distributed_sessions.md test/cluster_test.exs
git commit -m "feat(cluster): optional Normandy.Cluster helper + distributed sessions guide"
```

---

## Self-Review

- **Spec coverage (§7.6 eager, §7.8, Open questions):** durable resume point at `:steering` (Task 1); pure `Turn.resume/1` (Task 2); eager init auto-resume + load-from-store on reconstruct (Task 3); `:eager → :transient` redistribution proven (Task 4 Step 1, the §7.6 open question); end-to-end eager handoff across nodes (Task 4 Step 2); optional `Normandy.Cluster` helper + optional libcluster dep + guide (Task 5). ✓
- **Dual-interpreter rule:** Task 1 Step 4 wires `{:persist, _}` into `Turn.Driver` (the [[turn-server-separate-interpreter]] gotcha); Task 1 Step 5 updates affected driver tests.
- **Integration tests:** Task 1 Step 6 + Task 3 Step 6 run the full default suite (lazy/inline unchanged); the extra steering persist is a no-op inline and a cheap write in the server.
- **Credential invariant:** eager resume reconstructs creds node-locally (7c); no caller, no secrets moved (Task 3 NOTE).
- **Placeholder scan:** one **intentional** `flunk/1` (Task 4 Step 2) marks the combined peer+Postgres harness as not-done until implemented — this is a deliberate failing guard, not a silent placeholder, and is called out.
- **Type consistency:** `Turn.resume/1` returns `{State.t(), [tuple()]}` like `step/2`; `resume_policy` is `:lazy | :eager` everywhere (template, Data, supervisor `restart_for/1` in 7c); `interpret/2` transitions are reused unchanged by the `:resume` internal-event handler.
