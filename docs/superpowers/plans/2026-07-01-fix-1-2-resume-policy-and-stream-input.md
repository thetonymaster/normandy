# Fix 1 + Fix 2: Resume-Policy Threading and Streamed Tool-Input Fail-Loud — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make eager resume real (persisted templates carry the caller's `resume_policy` instead of a hardcoded `:lazy`) and make undecodable streamed tool inputs fail loud (error `tool_result`, tool never executed) instead of silently executing with `%{}`.

**Architecture:** Fix 1 threads the `resume_policy` already extracted in `Turn.Session.rehydrate_and_start/1` into `ConfigTemplate.from_config/3` and deletes the `:lazy`-stamping `/2` arity so no caller can silently regress. Fix 2 changes `Dispatch.normalize_tool_input/1` to return `{:error, {:invalid_tool_input, preview}}` on decode failure, adds an `input_error` field to `%ToolCall{}` so a failed decode keeps the call's `id`/`name`, and makes `Dispatch.classify/3` map tagged calls straight to an error `ToolResult` through the existing `{:deny, result}` verdict — which every shell (BaseAgent loop, streaming loop, Turn.Server) already routes into the normal result path, preserving batch completeness.

**Tech Stack:** Elixir, ExUnit, Poison

## Global Constraints

- **Interpreter constraint (from the spec):** Any change to `Turn.step/2` effects must be handled by ALL THREE interpreters — `Turn.Driver`, `Turn.Inline`, `Turn.Server` — or the unwired shell crashes with a `CaseClauseError`. **This plan introduces NO new Turn effects.** Fix 2 rides the existing `{:deny, %ToolResult{}}` classify verdict, which `Dispatch.dispatch_one/3` (Driver/Inline path) and `Turn.Server.dispatch/2` (`server.ex:446`, the `denied` list) already handle. Do not add effects.
- **Fail-closed invariant:** a tool call whose input failed to decode must NEVER execute — not with `%{}`, not with partial input.
- **Batch-completeness invariant:** every `tool_use` id must still get exactly one `tool_result`. The deny path produces a `%ToolResult{tool_call_id: call.id}` that flows through the normal result path, so no shell changes are needed.
- Run `mix format` before running tests (repo convention in CLAUDE.md). All existing tests must pass at plan completion. If tests fail, they must be fixed, even if they are items we were not working on.
- Work on a feature branch (e.g. `fix/critical-1-2-resume-policy-stream-input`), not `main`.
- **Commits:** `git add` files individually (never `git add .`), conventional commit messages, NO AI attribution and no `Co-Authored-By` lines.
- Dialyzer note: CI gates on Dialyzer. The transient states after Tasks 4–5 leave one direct `normalize_tool_input` caller in `base_agent.ex` that could theoretically place an error tuple in a `map()`-typed field; the final state (after Task 7) has no such caller. Run `mix dialyzer` at the end of Task 7; do not open the PR mid-plan.
- The distributed test (Task 3) requires Postgres and BEAM distribution; its full run command is given in the task. All other tasks run under plain `mix test`.

---

### Task 1: Thread `resume_policy` into `Turn.Session` template persistence

**Context for a zero-context implementer:** `Turn.Session.rehydrate_and_start/1` (`lib/normandy/agents/turn/session.ex`) is the production router in front of `Turn.Server`. When `opts[:template_provider]` is set (Tier-2 thin start), it persists a secret-free config template to the `SessionStore` at line 98 via `ConfigTemplate.from_config/2` — which hardcodes `resume_policy: :lazy` (`lib/normandy/agents/config_template.ex:21`). The caller's policy is already extracted at `session.ex:74` (`resume_policy = Keyword.get(opts, :resume_policy, :lazy)`) but never reaches the template. Consequence: `SessionStore.list_resumable/1` (which filters on `resume_policy == :eager`) always returns `[]` for production-persisted sessions, so the `ResumeReaper` never recovers anything.

**Files:**
- Modify: `/Users/antonio/personal/normandy/lib/normandy/agents/turn/session.ex` (lines 97–98)
- Test: `/Users/antonio/personal/normandy/test/agents/turn/session_test.exs` (add one test after the existing `"Tier-2 thin path rehydrates conversation history..."` test, before the `defp children_pids` helper)

**Interfaces:**
- Consumes: `Normandy.Agents.ConfigTemplate.from_config(config :: BaseAgentConfig.t(), template_id :: String.t(), resume_policy :: :lazy | :eager) :: map()` (this arity already exists)
- Produces: persisted template map whose `:resume_policy` equals the caller's `opts[:resume_policy]`
- Consumes (test): `Normandy.Behaviours.SessionStore.InMemory.load_config_template(pid, sid) :: {:ok, map()} | :error` and `list_resumable(pid) :: {:ok, [String.t()]}`

- [ ] **Step 1: Write the failing test**

Add to `/Users/antonio/personal/normandy/test/agents/turn/session_test.exs`, immediately after the `"Tier-2 thin path rehydrates conversation history into reconstructed server memory"` test and before `defp children_pids(sup)`:

```elixir
  test "session started :eager persists an :eager template visible to list_resumable/1" do
    # Regression for the dead eager-resume path: rehydrate_and_start/1 used
    # ConfigTemplate.from_config/2, which stamped :lazy regardless of the
    # caller's :resume_policy — so list_resumable/1 was always [] and the
    # ResumeReaper never had anything to recover.
    alias Normandy.Behaviours.SessionStore.InMemory
    alias Normandy.Behaviours.SessionRegistry.Native
    alias Normandy.Behaviours.AgentTemplate.Catalog
    alias Normandy.Test.TurnConfig

    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
    {:ok, cat} = Catalog.start_link([])
    sid = "eager-policy-#{System.unique_integer([:positive])}"

    config = TurnConfig.build()

    :ok =
      Catalog.put(cat, "eager-k", %{
        tool_registry: config.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _token -> config.client end
      })

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %TurnConfig.Resp{content: "ok"} end
    }

    opts = [
      session_id: sid,
      config: config,
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      template_provider: {Catalog, cat},
      template_id: "eager-k",
      resume_policy: :eager,
      handlers: handlers
    ]

    assert {:ok, _} = Normandy.Agents.Turn.Session.run(opts, "hello")

    assert {:ok, tmpl} = InMemory.load_config_template(store, sid)
    assert tmpl.resume_policy == :eager
    assert {:ok, [^sid]} = InMemory.list_resumable(store)
  end
```

- [ ] **Step 2: Run test to verify it fails**

```
mix format
mix test test/agents/turn/session_test.exs
```

Expected: **1 failure** (the new test), failing at `assert tmpl.resume_policy == :eager` with `Assertion with == failed`, `left: :lazy`, `right: :eager`. All pre-existing tests in the file pass.

- [ ] **Step 3: Write minimal implementation**

In `/Users/antonio/personal/normandy/lib/normandy/agents/turn/session.ex`, replace lines 97–98:

```elixir
            tmpl =
              Normandy.Agents.ConfigTemplate.from_config(config, template_id_of(opts, config))
```

with:

```elixir
            tmpl =
              Normandy.Agents.ConfigTemplate.from_config(
                config,
                template_id_of(opts, config),
                resume_policy
              )
```

(`resume_policy` is already bound at line 74 of the same function; no other change.)

- [ ] **Step 4: Run test to verify it passes**

```
mix format
mix test test/agents/turn/session_test.exs
```

Expected: **0 failures**.

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/turn/session.ex test/agents/turn/session_test.exs
git commit -m "fix(turn): persist caller resume_policy into session config template

rehydrate_and_start/1 stamped every production template :lazy via
ConfigTemplate.from_config/2, so list_resumable/1 was always empty and
the ResumeReaper never recovered eager sessions."
```

---

### Task 2: Delete `ConfigTemplate.from_config/2`; all callers pass an explicit policy

**Context:** Keeping an arity that silently stamps `:lazy` is the regression vector — a future caller could reintroduce the Fix-1 defect. `from_config/2` has no production callers after Task 1; remaining callers are tests: `test/agents/config_template_test.exs:22,51`, `test/agents/turn/server_test.exs:689`, `test/agents/turn/supervisor_horde_test.exs:19`. (`eager_resume_test.exs`, `eager_handoff_distributed_test.exs`, and `resume_reaper_integration_test.exs` already use `/3`.)

**Files:**
- Modify: `/Users/antonio/personal/normandy/lib/normandy/agents/config_template.ex` (lines 15–47: merge the two arities)
- Modify: `/Users/antonio/personal/normandy/test/agents/config_template_test.exs` (lines 22, 51 + new test)
- Modify: `/Users/antonio/personal/normandy/test/agents/turn/server_test.exs` (line 689)
- Modify: `/Users/antonio/personal/normandy/test/agents/turn/supervisor_horde_test.exs` (line 19)

**Interfaces:**
- Produces: `from_config(BaseAgentConfig.t(), String.t(), :lazy | :eager) :: map()` as the ONLY arity; `from_config/2` no longer exported.

- [ ] **Step 1: Write the failing test**

In `/Users/antonio/personal/normandy/test/agents/config_template_test.exs`:

(a) Change line 22 from `tmpl = ConfigTemplate.from_config(config, "support-agent")` to:

```elixir
    tmpl = ConfigTemplate.from_config(config, "support-agent", :lazy)
```

and add directly under the existing `assert tmpl.template_id == "support-agent"` (line 24):

```elixir
    assert tmpl.resume_policy == :lazy
```

(b) Change line 51 from `tmpl = ConfigTemplate.from_config(config, "capped-agent")` to:

```elixir
    tmpl = ConfigTemplate.from_config(config, "capped-agent", :lazy)
```

(c) Add this new test after the `"from_config carries the configured memory cap into max_messages"` test:

```elixir
  test "from_config/3 stamps the caller's resume_policy; the :lazy-stamping /2 stays deleted" do
    config = %BaseAgentConfig{
      model: "claude-x",
      temperature: 0.3,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 2,
      name: "support",
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: SomeInput,
      output_schema: SomeOutput,
      client: %{api_key: "SECRET", base_url: "https://api"},
      tool_registry: %Normandy.Tools.Registry{tools: %{"t" => %{}}},
      behaviours: %Config{}
    }

    assert ConfigTemplate.from_config(config, "eager-agent", :eager).resume_policy == :eager
    assert ConfigTemplate.from_config(config, "lazy-agent", :lazy).resume_policy == :lazy

    # from_config/2 silently stamped :lazy and masked the dead eager-resume
    # path (session.ex:98 was its only production caller). It must not return.
    Code.ensure_loaded!(ConfigTemplate)

    refute function_exported?(ConfigTemplate, :from_config, 2),
           "from_config/2 silently stamps :lazy — callers must pass an explicit policy"
  end
```

- [ ] **Step 2: Run test to verify it fails**

```
mix format
mix test test/agents/config_template_test.exs
```

Expected: **1 failure** — the new test, at the `refute function_exported?(ConfigTemplate, :from_config, 2)` line ("Expected false or nil, got true"). The two edited tests pass (the `/3` arity already exists).

- [ ] **Step 3: Write minimal implementation**

(a) In `/Users/antonio/personal/normandy/lib/normandy/agents/config_template.ex`, replace lines 15–47 (both `from_config` definitions and their specs) with a single merged definition:

```elixir
  @spec from_config(BaseAgentConfig.t(), String.t(), :lazy | :eager) :: map()
  def from_config(%BaseAgentConfig{} = c, template_id, resume_policy)
      when resume_policy in [:lazy, :eager] do
    b = c.behaviours || %Config{}

    %{
      template_id: template_id,
      resume_policy: resume_policy,
      model: c.model,
      temperature: c.temperature,
      max_tokens: c.max_tokens,
      max_tool_iterations: c.max_tool_iterations,
      max_tool_concurrency: c.max_tool_concurrency,
      name: c.name,
      prompt_specification: c.prompt_specification,
      input_schema: c.input_schema,
      output_schema: c.output_schema,
      max_messages: (c.memory && c.memory.max_messages) || nil,
      behaviours_refs: %{
        policy: b.policy,
        budget: b.budget,
        credential: b.credential,
        compactor: b.compactor,
        model_catalog: b.model_catalog,
        session_store: b.session_store,
        session_registry: b.session_registry
      }
    }
  end
```

(b) In `/Users/antonio/personal/normandy/test/agents/turn/server_test.exs`, change line 689 from:

```elixir
        Normandy.Agents.ConfigTemplate.from_config(base, "kind-a").behaviours_refs.credential,
```

to:

```elixir
        Normandy.Agents.ConfigTemplate.from_config(base, "kind-a", :lazy).behaviours_refs.credential,
```

(c) In `/Users/antonio/personal/normandy/test/agents/turn/supervisor_horde_test.exs`, change line 19 from:

```elixir
        Normandy.Agents.ConfigTemplate.from_config(base, "k").behaviours_refs.credential,
```

to:

```elixir
        Normandy.Agents.ConfigTemplate.from_config(base, "k", :lazy).behaviours_refs.credential,
```

- [ ] **Step 4: Run test to verify it passes**

```
mix format
mix test test/agents/config_template_test.exs test/agents/turn/server_test.exs test/agents/turn/supervisor_horde_test.exs
mix test
```

Expected: **0 failures** in the three targeted files, then **0 failures** on the full suite (proves no remaining `/2` caller anywhere).

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/config_template.ex test/agents/config_template_test.exs test/agents/turn/server_test.exs test/agents/turn/supervisor_horde_test.exs
git commit -m "refactor(config-template): delete from_config/2, require explicit resume_policy

The /2 arity hardcoded resume_policy: :lazy and was the regression
vector for the dead eager-resume path. All callers now state a policy."
```

---

### Task 3: Rewrite `eager_handoff_distributed_test` to persist the template through the real `Session.run` path

**Context:** The distributed handoff test (`test/agents/turn/eager_handoff_distributed_test.exs`) hand-built its `:eager` template with `from_config/3` and wrote it to the store directly — bypassing `session.ex:98` and thereby masking the Fix-1 defect. The spec requires it to persist through the real `Turn.Session.run/2` path. Bonus fix: the old `session_opts` had no `:config`, so the lazy-rehydration branch (`Session.run` after peer death) would have raised `KeyError` in `rehydrate_and_start/1` (`config = Keyword.fetch!(opts, :config)`); adding `config: base` fixes that latent crash. This is a test-only task: after Task 1 the production path is correct, so the rewritten test passes — its RED state can only be demonstrated by stashing the Task-1 change (optional, shown in Step 2).

**Files:**
- Modify: `/Users/antonio/personal/normandy/test/agents/turn/eager_handoff_distributed_test.exs` (the moduledoc paragraph "The harness seed path is fully verified..." and the entire `test "Postgres-backed session rehydrates on primary after peer death (lazy path)"` block, lines 108–247)

**Interfaces:**
- Consumes: `Normandy.Agents.Turn.Session.run(opts :: keyword(), user_input :: term()) :: {:ok, term()} | {:error, term()}`; `Normandy.Behaviours.SessionStore.Postgres.load_config_template(repo, sid)`, `list_resumable(repo)`, `save_turn_state(repo, sid, term)`
- Produces: no lib changes; test-only hardening

- [ ] **Step 1: Write the failing test** (rewrite; RED reproducible only pre-Task-1)

(a) In the moduledoc, replace the paragraph starting `The harness seed path is fully verified:` (lines 24–29) with:

```
  The `:eager` config template is persisted through the REAL production path —
  `Turn.Session.run/2` → `rehydrate_and_start/1` → `ConfigTemplate.from_config/3` —
  NOT hand-built (hand-building masked the from_config/2 :lazy-stamping defect).
  The test asserts the stored template carries `:eager` and is visible to
  `list_resumable/1`. A `:steering` turn state is then seeded directly. After the
  peer dies, a caller on the primary triggers LAZY rehydration via
  `Turn.Session.run/2`, which loads the config template from Postgres and
  reconstructs the server on the primary. The test asserts the session advances
  (the LLM stub resolves the :steering state).
```

(b) Replace the entire test block (lines 108–247) with:

```elixir
  test "Postgres-backed session rehydrates on primary after peer death (lazy path)", %{sid: sid} do
    repo = Normandy.TestRepo
    reg_name = :"handoff_reg_#{System.unique_integer([:positive])}"
    sup_name = :"handoff_sup_#{System.unique_integer([:positive])}"

    {:ok, _} = HReg.start_link(name: reg_name)
    {:ok, sup} = HSup.start_link(name: sup_name)
    {:ok, cat} = Catalog.start_link([])

    base = Normandy.Test.TurnConfig.build()

    # Register the supplement (tool_registry + client_builder + hooks).
    # TurnConfig.build/0 already carries {Normandy.Test.StubCreds, []} as the
    # credential behaviour, so from_config/3 copies it into the template.
    :ok =
      Catalog.put(cat, "k", %{
        tool_registry: base.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _ -> base.client end
      })

    # Stub call_llm so turns finalize without hitting a real LLM.
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req ->
          %Normandy.Test.TurnConfig.Resp{content: "resumed-done", tool_calls: nil}
        end
    }

    session_opts = [
      session_id: sid,
      config: base,
      store: {PGStore, repo},
      registry: {HReg, reg_name},
      supervisor: sup,
      supervisor_mod: HSup,
      template_provider: {Catalog, cat},
      template_id: "k",
      resume_policy: :eager,
      handlers: handlers
    ]

    # Persist the :eager config template through the REAL production path
    # (Session.run → rehydrate_and_start → ConfigTemplate.from_config/3).
    # Do NOT hand-build the template here: that masked the from_config/2
    # :lazy-stamping defect.
    assert {:ok, _} = Normandy.Agents.Turn.Session.run(session_opts, "seed")

    # Regression: the stored template carries the caller's :eager policy and
    # the session is visible to the ResumeReaper's query.
    assert {:ok, %{template_id: "k", resume_policy: :eager}} =
             PGStore.load_config_template(repo, sid)

    assert {:ok, resumable} = PGStore.list_resumable(repo)
    assert sid in resumable

    # Stop the seeded server so the rest of the test controls placement.
    {:ok, seeded} = HReg.whereis(reg_name, sid)
    :ok = GenServer.stop(seeded)

    assert wait_until(fn -> HReg.whereis(reg_name, sid) == :none end, 300),
           "Horde did not drop the seeded session registration after stop"

    # Seed a :steering turn state — the eager server will resume from it on init.
    steering = %Normandy.Agents.Turn.State{
      status: :steering,
      iterations_left: 1,
      max_iterations: 5
    }

    :ok = PGStore.save_turn_state(repo, sid, steering)

    assert match?(
             {:ok, %Normandy.Agents.Turn.State{status: :steering}},
             PGStore.load_turn_state(repo, sid)
           ),
           "turn state must be persisted in Postgres"

    # Start a peer node and give it DB access using the primary's repo config.
    {peer, node} = start_peer(~c"eagerhandoff")

    repo_opts =
      Application.get_env(:normandy, Normandy.TestRepo)
      |> Keyword.put(:pool, Ecto.Adapters.SQL.Sandbox)

    assert is_list(repo_opts), "could not fetch TestRepo config from app env"

    # Start Horde registry + supervisor on the peer (same names = same cluster).
    {:ok, _} = start_horde_on_peer(node, name: reg_name)
    {:ok, _} = start_horde_dsup_on_peer(node, sup_name)

    # Give the peer its own DB connection pool.
    case start_test_repo_on_peer(node, repo_opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        :peer.stop(peer)
        flunk("Failed to start TestRepo on peer: #{reason}")
    end

    # Wait for Horde membership to converge.
    assert wait_until(fn ->
             members = Horde.Cluster.members(reg_name)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde registry membership did not converge"

    assert wait_until(fn ->
             members = Horde.Cluster.members(sup_name)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde supervisor membership did not converge"

    # Start the Turn.Server somewhere in the cluster with THIN opts (no :config):
    # the server reconstructs its config from the template persisted above.
    # Horde decides which node; we don't control placement here.
    thin_opts = Keyword.delete(session_opts, :config)
    {:ok, server_pid} = HSup.start_server(sup, thin_opts)
    assert is_pid(server_pid)

    # Allow the eager resume to complete on wherever the server is hosted.
    Process.sleep(500)

    # If the server ended up on the peer, kill the peer and verify lazy rehydration.
    # If it ended up on the primary, just verify it's alive and the session is registered.
    case node(server_pid) do
      ^node ->
        # Server is on the peer — proceed to kill and test lazy rehydration.
        :peer.stop(peer)

        assert wait_until(fn -> HReg.whereis(reg_name, sid) == :none end, 300),
               "Horde did not drop the session registration after peer stopped"

        result = Normandy.Agents.Turn.Session.run(session_opts, "continue")

        assert match?({:ok, _}, result),
               "expected lazy rehydration to succeed after peer death, got: #{inspect(result)}"

        assert match?({:ok, _pid}, HReg.whereis(reg_name, sid)),
               "expected session to be registered on primary after lazy rehydration"

      _ ->
        # Server landed on the primary — the peer is irrelevant to this session.
        :peer.stop(peer)
        assert Process.alive?(server_pid), "server on primary must be alive"

        assert match?({:ok, ^server_pid}, HReg.whereis(reg_name, sid)),
               "session must be registered on primary"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

This test is excluded from plain runs (`@moduletag :distributed`); the compile check is always available:

```
mix format
mix test test/agents/turn/eager_handoff_distributed_test.exs
```

Expected: **0 failures, 1 excluded** (proves the rewritten file compiles).

RED demonstration (optional, only with Postgres running): `git stash push lib/normandy/agents/turn/session.ex` to temporarily revert Task 1, then run

```
elixir --name primary@127.0.0.1 -S mix test.postgres test/agents/turn/eager_handoff_distributed_test.exs --include distributed
```

Expected pre-fix failure: `match (=) failed` on `{:ok, %{template_id: "k", resume_policy: :eager}}` (stored template says `resume_policy: :lazy`). Then `git stash pop`.

- [ ] **Step 3: Write minimal implementation**

None — this is a test-only hardening task. Lib behavior was fixed in Task 1.

- [ ] **Step 4: Run test to verify it passes**

With Postgres available:

```
mix format
elixir --name primary@127.0.0.1 -S mix test.postgres test/agents/turn/eager_handoff_distributed_test.exs --include distributed
```

Expected: **0 failures**. Without Postgres, the compile-only check from Step 2 must show 0 failures / 1 excluded, and the full-distributed run must be executed before merge.

- [ ] **Step 5: Commit**

```
git add test/agents/turn/eager_handoff_distributed_test.exs
git commit -m "test(turn): persist eager-handoff template via the real Session.run path

Hand-building the template with from_config/3 bypassed session.ex and
masked the :lazy-stamping defect. Also supplies :config in session_opts,
fixing a latent KeyError in the lazy-rehydration branch."
```

---

### Task 4: `Dispatch.normalize_tool_input/1` returns an error tuple on undecodable input

**Context:** `lib/normandy/agents/dispatch.ex:346-351` currently converts a binary input that fails `Poison.decode` into `%{}` — the tool then executes silently with empty arguments. Streamed tool inputs arrive as accumulated `partial_json` strings (`StreamProcessor.append_json_delta/3`), so a truncated stream produces exactly this shape. This task changes only the normalization contract; tagging (Task 5) and denial (Task 6) build on it. Intermediate safety: the only behavior change existing callers can observe is for undecodable binaries, which no existing test exercises; `normalize_tool_input({:error, ...})` re-entering via the catch-all still yields `%{}`, preserving today's behavior until Task 6 lands.

**Files:**
- Modify: `/Users/antonio/personal/normandy/lib/normandy/agents/dispatch.ex` (lines 342–353, the `normalize_tool_input/1` clauses)
- Test: `/Users/antonio/personal/normandy/test/agents/dispatch_test.exs` (new `describe` block at the end of the module, after the last existing `describe`)

**Interfaces:**
- Produces: `normalize_tool_input(term()) :: map() | {:error, {:invalid_tool_input, String.t()}}` — error tuple only for binaries that fail to decode to a map; `nil`→`%{}`, map→map, other non-binaries→`%{}` (unchanged); preview truncated to 200 characters.

- [ ] **Step 1: Write the failing test**

Add at the end of `/Users/antonio/personal/normandy/test/agents/dispatch_test.exs`, before the final `end` of the module:

```elixir
  describe "normalize_tool_input/1" do
    test "nil and maps pass through unchanged" do
      assert Dispatch.normalize_tool_input(nil) == %{}
      assert Dispatch.normalize_tool_input(%{"a" => 1}) == %{"a" => 1}
    end

    test "valid JSON object string decodes to a map" do
      assert Dispatch.normalize_tool_input(~s({"city":"SF"})) == %{"city" => "SF"}
    end

    test "undecodable string (truncated streamed partial_json) returns a tagged error" do
      truncated = ~s({"city": "SF)

      assert Dispatch.normalize_tool_input(truncated) ==
               {:error, {:invalid_tool_input, truncated}}
    end

    test "JSON string decoding to a non-map is invalid tool input" do
      assert Dispatch.normalize_tool_input("[1,2,3]") ==
               {:error, {:invalid_tool_input, "[1,2,3]"}}
    end

    test "preview is truncated to 200 characters" do
      long = "{" <> String.duplicate("x", 500)

      assert {:error, {:invalid_tool_input, preview}} = Dispatch.normalize_tool_input(long)
      assert String.length(preview) == 200
    end

    test "non-binary, non-map input still degrades to %{} (unchanged contract)" do
      assert Dispatch.normalize_tool_input([1, 2, 3]) == %{}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```
mix format
mix test test/agents/dispatch_test.exs
```

Expected: **3 failures** — "undecodable string" and "non-map JSON" fail with `Assertion with == failed`, `left: %{}`; "preview is truncated" fails with `match (=) failed` (got `%{}`). The other three new tests and all pre-existing tests pass.

- [ ] **Step 3: Write minimal implementation**

In `/Users/antonio/personal/normandy/lib/normandy/agents/dispatch.ex`, replace lines 342–353:

```elixir
  @doc false
  def normalize_tool_input(nil), do: %{}
  def normalize_tool_input(input) when is_map(input), do: input

  def normalize_tool_input(input) when is_binary(input) do
    case Poison.decode(input) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  def normalize_tool_input(_), do: %{}
```

with:

```elixir
  @invalid_input_preview_chars 200

  @doc false
  def normalize_tool_input(nil), do: %{}
  def normalize_tool_input(input) when is_map(input), do: input

  def normalize_tool_input(input) when is_binary(input) do
    case Poison.decode(input) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> {:error, {:invalid_tool_input, truncate_preview(input)}}
    end
  end

  def normalize_tool_input(_), do: %{}

  # Preview of a malformed payload for error messages: grapheme-safe truncation;
  # non-UTF-8 bytes are inspected so the preview can always be JSON-encoded
  # downstream (ToolResult output flows through Poison.encode!).
  defp truncate_preview(raw) do
    if String.valid?(raw) do
      String.slice(raw, 0, @invalid_input_preview_chars)
    else
      raw
      |> binary_part(0, min(byte_size(raw), @invalid_input_preview_chars))
      |> inspect()
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

```
mix format
mix test test/agents/dispatch_test.exs test/agents/dispatch_split_test.exs
```

Expected: **0 failures** in both files.

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/dispatch.ex test/agents/dispatch_test.exs
git commit -m "refactor(dispatch): normalize_tool_input returns tagged error on undecodable input

Undecodable streamed partial_json no longer degrades to %{}; it returns
{:error, {:invalid_tool_input, preview}} (preview capped at 200 chars)."
```

---

### Task 5: `ToolCall.input_error` field + tagging in `Dispatch.to_tool_call/1`

**Context:** With Task 4's error tuple in hand, the streamed-block → `%ToolCall{}` conversion must keep the call's `id`/`name` (batch completeness needs the id) and carry the failure. Mechanism (per spec): a new optional `input_error` field on `%ToolCall{}` (`lib/normandy/components/tool_call.ex`), default `nil`, holding the malformed-payload preview string. A string (not the tuple) keeps the struct trivially serializable — `ToolCallResponse`'s `BaseIOSchema.to_json/1` reads only `id`/`name`/`input`, and `input` stays `%{}` on tagged calls. `classify/3`'s direct `normalize_tool_input` call is switched to `to_tool_call/1` here so no error tuple is ever assigned to the `map()`-typed `input` field; behavior is unchanged in this task (tagged calls still execute with `%{}` until Task 6 adds the deny).

**Files:**
- Modify: `/Users/antonio/personal/normandy/lib/normandy/components/tool_call.ex` (lines 10–20)
- Modify: `/Users/antonio/personal/normandy/lib/normandy/agents/dispatch.ex` (lines 75–85 `to_tool_call/1`; line 184 in `classify/3`)
- Test: `/Users/antonio/personal/normandy/test/agents/dispatch_test.exs` (two tests added inside the existing `describe "to_tool_call/1"` block)

**Interfaces:**
- Produces: `%Normandy.Components.ToolCall{id: String.t(), name: String.t(), input: map(), input_error: String.t() | nil}`
- Produces: `to_tool_call(ToolCall.t() | map()) :: ToolCall.t()` (unchanged spec) — on decode failure: `input: %{}`, `input_error: preview`, `id`/`name` preserved.

- [ ] **Step 1: Write the failing test**

Add inside the existing `describe "to_tool_call/1"` block of `/Users/antonio/personal/normandy/test/agents/dispatch_test.exs`, after the `"decodes a JSON-string input and degrades non-map input to %{}"` test:

```elixir
    test "keeps id/name and tags input_error when a JSON-string input fails to decode" do
      truncated = ~s({"city": "SF)

      tagged = Dispatch.to_tool_call(%ToolCall{id: "c-t1", name: "weather", input: truncated})
      assert %ToolCall{id: "c-t1", name: "weather", input: %{}, input_error: ^truncated} = tagged

      raw = %{"id" => "c-t2", "name" => "weather", "input" => truncated}

      assert %ToolCall{id: "c-t2", name: "weather", input: %{}, input_error: ^truncated} =
               Dispatch.to_tool_call(raw)
    end

    test "decodable and empty inputs leave input_error nil" do
      raw = %{"id" => "c-t3", "name" => "weather", "input" => ~s({"city":"SF"})}
      assert %ToolCall{input: %{"city" => "SF"}, input_error: nil} = Dispatch.to_tool_call(raw)

      assert %ToolCall{input: %{}, input_error: nil} =
               Dispatch.to_tool_call(%ToolCall{id: "c-t4", name: "weather", input: nil})
    end
```

- [ ] **Step 2: Run test to verify it fails**

```
mix format
mix test test/agents/dispatch_test.exs
```

Expected: **compile error** — `** (CompileError) test/agents/dispatch_test.exs: unknown key :input_error for struct Normandy.Components.ToolCall` (the field does not exist yet).

- [ ] **Step 3: Write minimal implementation**

(a) In `/Users/antonio/personal/normandy/lib/normandy/components/tool_call.ex`, replace lines 10–20:

```elixir
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map()
        }

  schema do
    field(:id, :string)
    field(:name, :string)
    field(:input, :map)
  end
```

with:

```elixir
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map(),
          input_error: String.t() | nil
        }

  schema do
    field(:id, :string)
    field(:name, :string)
    field(:input, :map)

    # Set when LLM-supplied input (e.g. accumulated streamed partial_json)
    # failed to decode: a truncated preview of the malformed payload. A tagged
    # call is mapped to an error ToolResult by Dispatch.classify/3 instead of
    # being executed with fabricated %{} arguments.
    field(:input_error, :string)
  end
```

(b) In `/Users/antonio/personal/normandy/lib/normandy/agents/dispatch.ex`, replace the `to_tool_call/1` definitions (lines 75–85):

```elixir
  @doc "Normalizes a raw LLM tool call (struct or string-keyed map) into a %ToolCall{}."
  @spec to_tool_call(ToolCall.t() | map()) :: ToolCall.t()
  def to_tool_call(%ToolCall{} = call), do: %{call | input: normalize_tool_input(call.input)}

  def to_tool_call(%{} = raw) do
    %ToolCall{
      id: raw["id"] || raw[:id],
      name: raw["name"] || raw[:name],
      input: normalize_tool_input(raw["input"] || raw[:input])
    }
  end
```

with:

```elixir
  @doc """
  Normalizes a raw LLM tool call (struct or string-keyed map) into a %ToolCall{}.

  A JSON-string input that fails to decode does NOT degrade to `%{}`: the call
  keeps its `id`/`name`, `input` becomes `%{}`, and `input_error` carries a
  truncated preview of the malformed payload so `classify/3` can fail loud
  instead of executing the tool with fabricated empty arguments.
  """
  @spec to_tool_call(ToolCall.t() | map()) :: ToolCall.t()
  def to_tool_call(%ToolCall{} = call) do
    case normalize_tool_input(call.input) do
      {:error, {:invalid_tool_input, preview}} ->
        %{call | input: %{}, input_error: preview}

      input ->
        %{call | input: input}
    end
  end

  def to_tool_call(%{} = raw) do
    to_tool_call(%ToolCall{
      id: raw["id"] || raw[:id],
      name: raw["name"] || raw[:name],
      input: raw["input"] || raw[:input]
    })
  end
```

(c) Still in `dispatch.ex`, inside `classify/3`'s `%ToolCall{}` clause, replace line 184:

```elixir
    call = %{call | input: normalize_tool_input(call.input)}
```

with:

```elixir
    call = to_tool_call(call)
```

(Behavior-preserving here — a tagged call still proceeds with `input: %{}` exactly as before; Task 6 adds the deny. This keeps the error tuple out of the `map()`-typed `input` field.)

- [ ] **Step 4: Run test to verify it passes**

```
mix format
mix test test/agents/dispatch_test.exs test/agents/dispatch_split_test.exs test/agents/base_agent_streaming_test.exs
```

Expected: **0 failures** (existing `to_tool_call` equality tests still pass because struct literals get `input_error: nil` by default).

- [ ] **Step 5: Commit**

```
git add lib/normandy/components/tool_call.ex lib/normandy/agents/dispatch.ex test/agents/dispatch_test.exs
git commit -m "feat(dispatch): tag ToolCall with input_error when streamed input fails to decode

to_tool_call/1 keeps id/name, sets input: %{} and input_error: preview.
No behavior change at classify yet; denial lands in the next commit."
```

---

### Task 6: `Dispatch.classify/3` denies input-error-tagged calls without executing

**Context:** `classify/3` (`dispatch.ex`) is the side-effect-free half of the chokepoint; every shell routes its `{:deny, %ToolResult{}}` verdict into the normal result path (`dispatch_one/3` returns it; `Turn.Server.dispatch/2` collects it in `denied`). Mapping tagged calls to `{:deny, ...}` therefore guarantees both invariants at once: the tool never executes, and the batch still contains a `tool_result` for the call's `tool_use` id.

**Files:**
- Modify: `/Users/antonio/personal/normandy/lib/normandy/agents/dispatch.ex` (the `classify/3` clauses, lines 177–215 after Task 5; new private helper `invalid_input_result/1` next to `not_found_result/1`, ~line 334)
- Test: `/Users/antonio/personal/normandy/test/agents/dispatch_test.exs` (new `describe` block at the end of the module)

**Interfaces:**
- Consumes: `%ToolCall{input_error: String.t()}` (tagged by Task 5)
- Produces: `classify(map(), ToolCall.t() | map(), Pipeline.t()) :: {:execute, struct(), ToolCall.t()} | {:deny, ToolResult.t()} | {:needs_approval, struct(), ToolCall.t(), map()}` (unchanged spec); tagged call → `{:deny, %ToolResult{tool_call_id: call.id, is_error: true, output: %{error: message_naming_tool_and_preview, invalid_input: true}}}`

- [ ] **Step 1: Write the failing test**

Add at the end of `/Users/antonio/personal/normandy/test/agents/dispatch_test.exs`, before the final `end` of the module:

```elixir
  describe "classify/3 invalid streamed input" do
    test "input-error-tagged call → {:deny, error ToolResult} naming tool and preview" do
      config = config_with_tools([%FakeTool{}])
      truncated = ~s({"city": "SF)
      call = Dispatch.to_tool_call(%{"id" => "c-bad", "name" => "weather", "input" => truncated})

      assert {:deny, %ToolResult{tool_call_id: "c-bad", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert result.output.error =~ "weather"
      assert result.output.error =~ truncated
    end

    test "dispatch_one on a raw call with undecodable input returns the error result, tool not run" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c-bad2", "name" => "weather", "input" => ~s({"city": "SF)}

      result = Dispatch.dispatch_one(config, raw, Dispatch.default_pipeline())

      # Executing with %{} would have produced {output: "weather in ", is_error: false}
      # (see the nil-input test above) — an error result proves the deny path ran instead.
      assert %ToolResult{tool_call_id: "c-bad2", is_error: true} = result
      assert result.output.invalid_input == true
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```
mix format
mix test test/agents/dispatch_test.exs
```

Expected: **2 failures** — the classify test fails with `match (=) failed` (got `{:execute, %FakeTool{}, %ToolCall{...}}`); the dispatch_one test fails with `match (=) failed` (got `%ToolResult{output: "weather in ", is_error: false}` — today's silent-execution defect, live on stage).

- [ ] **Step 3: Write minimal implementation**

(a) In `/Users/antonio/personal/normandy/lib/normandy/agents/dispatch.ex`, replace the three `classify/3` clause definitions (the bodyless head plus the `%ToolCall{}` and raw-map clauses — after Task 5 the `%ToolCall{}` clause begins with `call = to_tool_call(call)`) with:

```elixir
  def classify(config, tool_call, pipeline \\ default_pipeline())

  def classify(config, %ToolCall{input_error: nil} = call, %Pipeline{} = pipeline) do
    case to_tool_call(call) do
      %ToolCall{input_error: nil} = call ->
        case Registry.get(config.tool_registry, call.name) do
          {:ok, tool} ->
            case run_before_hooks(config, call, pipeline.before_hooks) do
              {:halt, %ToolResult{} = result} ->
                {:deny, result}

              {:cont, call} ->
                prepared = prepare_tool(tool, call.input)

                case validate_input(tool, call.input) do
                  {:error, errors} ->
                    {:deny, validation_error_result(call, errors)}

                  :ok ->
                    case apply_policy(pipeline, config, call, prepared) do
                      {:allow, _meta} -> {:execute, prepared, call}
                      {:deny, info} -> {:deny, denial_result(call, info, false)}
                      {:needs_approval, info} -> {:needs_approval, prepared, call, info}
                    end
                end
            end

          :error ->
            {:deny, not_found_result(call)}
        end

      %ToolCall{} = tagged ->
        {:deny, invalid_input_result(tagged)}
    end
  end

  # A call already tagged with an input decode failure is mapped straight to an
  # error ToolResult — the tool is NEVER executed with fabricated %{} arguments.
  # Routing through the normal {:deny, result} verdict preserves batch
  # completeness: every tool_use still gets a tool_result.
  def classify(_config, %ToolCall{} = call, %Pipeline{}) do
    {:deny, invalid_input_result(call)}
  end

  def classify(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    classify(config, to_tool_call(raw_call), pipeline)
  end
```

(Clause order matters: `input_error: nil` first, then the tagged `%ToolCall{}` catch-all, then the raw map — a `%ToolCall{}` is also a map, so the struct clauses must precede it, as they already do today.)

(b) Add the helper after the existing `not_found_result/1` (currently lines 334–340), before `normalize_tool_input/1`:

```elixir
  defp invalid_input_result(%ToolCall{} = call) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{
        error:
          "invalid tool input for '#{call.name}': streamed arguments were not " <>
            "valid JSON (preview: #{call.input_error})",
        invalid_input: true
      },
      is_error: true
    }
  end
```

(c) Append one line to the `classify/3` `@doc` (after the `* {:needs_approval, ...}` bullet):

```
    * a call tagged with `input_error` (undecodable streamed input) maps directly
      to `{:deny, error ToolResult}` — the tool is never executed.
```

- [ ] **Step 4: Run test to verify it passes**

```
mix format
mix test test/agents/dispatch_test.exs test/agents/dispatch_split_test.exs test/agents/turn/server_test.exs
```

Expected: **0 failures** in all three files (server_test exercises `Turn.Server.dispatch/2`, which consumes classify verdicts).

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/dispatch.ex test/agents/dispatch_test.exs
git commit -m "fix(dispatch): deny input-error-tagged tool calls instead of executing with %{}

classify/3 maps a ToolCall carrying input_error straight to an error
ToolResult (is_error: true, message naming the tool and the malformed
payload preview). The {:deny, result} verdict rides the normal result
path, so every tool_use still gets a tool_result."
```

---

### Task 7: Streamed-block → ToolCall conversion keeps the error tag; end-to-end streaming test

**Context:** `BaseAgent.build_streaming_assistant_response/2` (`lib/normandy/agents/base_agent.ex:955-981`) converts streamed `tool_use` blocks into `%ToolCall{}` structs for memory persistence, currently via a bare `Dispatch.normalize_tool_input(block["input"])` at line 971 — which, after Task 4, would place the error tuple in `input`. Replacing the hand-rolled conversion with `Dispatch.to_tool_call/1` keeps `id`/`name` and carries the failure on `input_error`. The dispatch side needs no change: `dispatch_stream_tools/3` already feeds the raw blocks through `dispatch_one/3` → `to_tool_call/1` → `classify/3`, which now denies. This task closes the loop and adds the spec-mandated end-to-end test: streamed truncated `partial_json` → tool never invoked, error `tool_result` with the matching `tool_call_id`.

**Files:**
- Modify: `/Users/antonio/personal/normandy/lib/normandy/agents/base_agent.ex` (lines 955–979, `build_streaming_assistant_response/2`)
- Create: `/Users/antonio/personal/normandy/test/agents/base_agent_streaming_invalid_input_test.exs`

**Interfaces:**
- Consumes: `Dispatch.to_tool_call(map()) :: ToolCall.t()` (Task 5)
- Produces: persisted assistant `%ToolCallResponse{tool_calls: [%ToolCall{id: ..., name: ..., input: %{}, input_error: preview}]}` for blocks whose accumulated `partial_json` failed to decode

- [ ] **Step 1: Write the failing test**

Create `/Users/antonio/personal/normandy/test/agents/base_agent_streaming_invalid_input_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentStreamingInvalidInputTest do
  @moduledoc """
  Fix 2 end-to-end: a streamed tool_use whose accumulated partial_json is
  truncated (stream died mid-arguments) must (a) never invoke the tool and
  (b) produce an error tool_result with the matching tool_call_id, keeping
  the batch complete for the follow-up LLM call.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  # Truncated JSON: decoding fails, so the input cannot be reconstructed.
  @truncated_json ~s({"city": "SF)

  defmodule SpyTool do
    defstruct owner: nil

    defimpl Normandy.Tools.BaseTool do
      def tool_name(_), do: "spy"
      def tool_description(_), do: "Reports execution to the test process"
      def input_schema(_), do: %{type: "object", properties: %{}, required: []}

      def run(tool) do
        send(tool.owner, :spy_executed)
        {:ok, "ran"}
      end
    end
  end

  defmodule TruncatedToolInputClient do
    use Normandy.Schema

    schema do
      field(:marker, :string, default: "")
    end

    defimpl Normandy.Agents.Model do
      def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
        do: response_model

      def converse(_client, _model, _temperature, _max_tokens, _messages, response_model, _opts),
        do: response_model

      def stream_converse(
            _client,
            _model,
            _temperature,
            _max_tokens,
            messages,
            _response_model,
            opts \\ []
          ) do
        _callback = Keyword.get(opts, :callback)

        # First call streams a tool_use whose partial_json dies mid-payload;
        # the follow-up call (history now contains a role "tool" entry) ends
        # the turn with plain text.
        has_tool_result = Enum.any?(messages, &match?(%{role: "tool"}, &1))

        events =
          if has_tool_result do
            [
              %{
                type: "message_start",
                message: %{"id" => "msg_2", "model" => "claude-3", "role" => "assistant"}
              },
              %{
                type: "content_block_start",
                content_block: %{"type" => "text", "text" => ""},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "text_delta", "text" => "done"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          else
            [
              %{
                type: "message_start",
                message: %{"id" => "msg_1", "model" => "claude-3", "role" => "assistant"}
              },
              %{
                type: "content_block_start",
                content_block: %{"type" => "tool_use", "id" => "tool_bad_1", "name" => "spy"},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "input_json_delta", "partial_json" => ~s({"city": "SF)},
                index: 0
              },
              %{type: "message_stop"}
            ]
          end

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  test "truncated streamed tool input: tool never runs, error tool_result carries the call id" do
    config =
      BaseAgent.init(%{
        client: %TruncatedToolInputClient{},
        model: "claude-3",
        temperature: 0.7
      })

    config = BaseAgent.register_tool(config, %SpyTool{owner: self()})

    # tool_result callbacks run in Task.async_stream workers — capture the
    # test pid outside the callback (self() inside would target the worker).
    parent = self()

    callback = fn
      :tool_result, result -> send(parent, {:tool_result, result})
      _, _ -> :ok
    end

    {updated_config, _response} =
      BaseAgent.stream_with_tools(config, %{chat_message: "go"}, callback)

    # (a) the tool is never invoked.
    refute_received :spy_executed

    # (b) an error tool_result with the matching tool_call_id is produced,
    # naming the tool and the malformed-payload preview.
    assert_received {:tool_result,
                     %ToolResult{tool_call_id: "tool_bad_1", is_error: true} = result}

    assert result.output.error =~ "spy"
    assert result.output.error =~ @truncated_json

    # The persisted assistant turn keeps the call's id/name and the error tag
    # (build_streaming_assistant_response must not stuff a decode-error tuple
    # into ToolCall.input).
    assistant_call =
      updated_config.memory
      |> AgentMemory.messages()
      |> Enum.find_value(fn
        %{role: "assistant", content: %Normandy.Agents.ToolCallResponse{tool_calls: [call | _]}} ->
          call

        _ ->
          nil
      end)

    assert %ToolCall{id: "tool_bad_1", name: "spy", input: %{}, input_error: @truncated_json} =
             assistant_call
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```
mix format
mix test test/agents/base_agent_streaming_invalid_input_test.exs
```

Expected: **1 failure**. The dispatch-side assertions (a) and (b) already pass (Tasks 4–6), but the final memory assertion fails with `match (=) failed`: `assistant_call.input` is the raw tuple `{:error, {:invalid_tool_input, "{\"city\": \"SF"}}` and `input_error` is `nil` — proving `build_streaming_assistant_response/2` still bypasses the tagging.

- [ ] **Step 3: Write minimal implementation**

In `/Users/antonio/personal/normandy/lib/normandy/agents/base_agent.ex`, replace lines 955–979 (`build_streaming_assistant_response/2`, first clause):

```elixir
  defp build_streaming_assistant_response(%{content: content}, tool_calls)
       when is_list(content) do
    alias Normandy.Agents.ToolCallResponse
    alias Normandy.Components.ToolCall

    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join("")

    calls =
      Enum.map(tool_calls || [], fn block ->
        %ToolCall{
          id: block["id"],
          name: block["name"],
          input: Dispatch.normalize_tool_input(block["input"])
        }
      end)

    %ToolCallResponse{
      content: if(text == "", do: nil, else: text),
      tool_calls: calls
    }
  end
```

with:

```elixir
  defp build_streaming_assistant_response(%{content: content}, tool_calls)
       when is_list(content) do
    alias Normandy.Agents.ToolCallResponse

    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join("")

    # A block whose accumulated partial_json failed to decode keeps its id/name
    # and carries the failure on ToolCall.input_error (Dispatch.to_tool_call/1),
    # so Dispatch.classify/3 fails loud instead of executing the tool with %{}.
    calls = Enum.map(tool_calls || [], &Dispatch.to_tool_call/1)

    %ToolCallResponse{
      content: if(text == "", do: nil, else: text),
      tool_calls: calls
    }
  end
```

(Note the function-local `alias Normandy.Components.ToolCall` is removed — it would otherwise trigger an unused-alias warning.)

- [ ] **Step 4: Run test to verify it passes**

```
mix format
mix test test/agents/base_agent_streaming_invalid_input_test.exs test/agents/base_agent_streaming_test.exs test/agents/base_agent_streaming_guardrails_test.exs
mix test
mix dialyzer
```

Expected: **0 failures** on the targeted files, **0 failures** on the full suite, Dialyzer clean (CI gates on it; the last direct `normalize_tool_input` caller outside `Dispatch` is gone).

- [ ] **Step 5: Commit**

```
git add lib/normandy/agents/base_agent.ex test/agents/base_agent_streaming_invalid_input_test.exs
git commit -m "fix(agents): route streamed tool_use blocks through Dispatch.to_tool_call/1

A truncated streamed partial_json no longer becomes a silent %{} (or a
decode-error tuple in ToolCall.input): the persisted call keeps id/name
and carries input_error, the tool never executes, and an error
tool_result with the matching tool_call_id keeps the batch complete."
```
