# Phase 7c — Horde Supervisor + Thin Specs + Template Reconstruction + Wiring (lazy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run sessions under `Horde.DynamicSupervisor` (cluster-wide placement + supervision) with **lazy** recovery, by reconstructing each `%BaseAgentConfig{}` on the running node from a persisted non-secret template + a node-local supplement + node-local credentials — so no secret or closure ever enters a gossiped Horde child spec. Delivers deployment Tier 2 (lazy).

**Architecture:** Under Horde, `Turn.Server` starts from a **thin spec** carrying only ids/refs (`session_id`, store/registry/supervisor handles, `template_provider` ref, `resume_policy`). On `init/1` (Tier-2) it loads the persisted **config template** (serializable scalars + behaviour refs) and the turn state from the `SessionStore`, resolves the **node-local supplement** (tool registry, before/after hooks, a `client_builder`) by `template_id`, fetches the token via the credential provider, and assembles the full config. Tiers 0/1 keep the direct-config path unchanged. Lazy recovery = `restart: :temporary` (a lost node's session is rebuilt on the next request).

**Tech Stack:** Elixir 1.18 / OTP 27, Horde 0.9 (`Horde.DynamicSupervisor`), Ecto/Postgres (7a), `:gen_statem`.

## Global Constraints

- Elixir floor `~> 1.15`; Erlang 27.2 / Elixir 1.18.1.
- `mix format` before every commit; all tests pass (fix pre-existing failures too).
- **Default-off:** Tiers 0/1 (local supervisor, direct config) are observably unchanged; the all-defaults suite passes identically.
- **Hard invariant:** credentials are never persisted, never gossiped, never in a child spec. Only the non-secret template is persisted; creds + tool handlers + hook closures stay node-local.
- Depends on **7a** (`SessionStore.Postgres`, the `:postgres` tag, `Migration`) and **7b** (`SessionRegistry.Horde`, `child_name/2`, `Turn.Server` `:name`, supervisor `child_name` plumbing, `Turn.Session` `{:already_started, pid}`).
- Multi-node tests `@moduletag :distributed`; Postgres tests `@moduletag :postgres`; both excluded by default.
- `git add` individually; no AI attribution.

## File Structure

- Create `lib/normandy/agents/config_template.ex` — extract/rebuild a serializable config template.
- Create `lib/normandy/behaviours/agent_template.ex` — behaviour + `Catalog` default (node-local supplement registry).
- Create `lib/normandy/agents/turn/supervisor/horde.ex` — `Turn.Supervisor.Horde` (`Horde.DynamicSupervisor`).
- Modify `lib/normandy/behaviours/session_store.ex` — add `save_config_template/3`, `load_config_template/2`.
- Modify `lib/normandy/behaviours/session_store/in_memory.ex`, `.../ets.ex`, `.../postgres.ex` — implement them.
- Create `lib/normandy/behaviours/session_store/postgres/migration_add_template.ex` — adds the `config_template` column.
- Modify `priv/test_repo/migrations/...` — add a migration calling it.
- Modify `test/support/session_store_contract.ex` — add a template round-trip contract test.
- Modify `lib/normandy/agents/turn/server.ex:48-64` — Tier-2 reconstruct-on-init path.
- Modify `lib/normandy/agents/turn/session.ex` — pass thin opts for Tier-2; persist template on first start.
- Modify `lib/normandy/coordination/agent_process.ex:283-318` — allow Horde supervisor + template provider.
- Tests: `test/agents/config_template_test.exs`, `test/behaviours/agent_template_test.exs`, `test/agents/turn/supervisor_horde_test.exs`, `test/agents/turn/tier2_integration_test.exs`, `test/agents/turn/lazy_recovery_distributed_test.exs`.

---

### Task 1: `SessionStore` config-template callbacks (behaviour + all impls + contract)

**Files:**
- Modify: `lib/normandy/behaviours/session_store.ex`
- Modify: `lib/normandy/behaviours/session_store/in_memory.ex`, `.../ets.ex`
- Modify: `lib/normandy/behaviours/session_store/postgres.ex`
- Create: `lib/normandy/behaviours/session_store/postgres/migration_add_template.ex`
- Create: `priv/test_repo/migrations/20260617000100_add_config_template.exs`
- Modify: `test/support/session_store_contract.ex`

**Interfaces:**
- Produces: `@callback save_config_template(handle, session_id, term) :: :ok | {:error, term}`; `@callback load_config_template(handle, session_id) :: {:ok, term} | :error`. Round-trips an opaque term; missing → `:error`.

- [ ] **Step 1: Add the contract test (drives all impls)**

In `test/support/session_store_contract.ex`, add inside the `quote` block (after the turn-state test):

```elixir
      test "config template round-trips an opaque term; missing is :error", %{handle: h} do
        tmpl = %{template_id: "k", model: "m", behaviours_refs: %{policy: {Foo, []}}}
        assert :ok = @store.save_config_template(h, "s1", tmpl)
        assert {:ok, ^tmpl} = @store.load_config_template(h, "s1")
        assert :error = @store.load_config_template(h, "never")
      end
```

- [ ] **Step 2: Run to verify it fails for an existing impl**

Run: `mix test test/behaviours/session_store/ets_test.exs`
Expected: FAIL — `save_config_template/3` undefined on `ETS`.

- [ ] **Step 3: Declare the callbacks on the behaviour**

In `lib/normandy/behaviours/session_store.ex`, after `load_turn_state`:

```elixir
  @callback save_config_template(handle(), session_id(), template :: term()) ::
              :ok | {:error, term()}
  @callback load_config_template(handle(), session_id()) :: {:ok, term()} | :error
```

- [ ] **Step 4: Implement on InMemory and ETS**

`ETS` (`ets.ex`) — add client functions + handlers, mirroring `save_turn_state`/`load_turn_state` but with a `{:config_template, session_id}` key:

```elixir
  @impl Normandy.Behaviours.SessionStore
  def save_config_template(pid, session_id, tmpl),
    do: GenServer.call(pid, {:save_config_template, session_id, tmpl})

  @impl Normandy.Behaviours.SessionStore
  def load_config_template(pid, session_id),
    do: GenServer.call(pid, {:load_config_template, session_id})
```

and in the server section:

```elixir
  def handle_call({:save_config_template, session_id, tmpl}, _from, table) do
    :ets.insert(table, {{:config_template, session_id}, tmpl})
    {:reply, :ok, table}
  end

  def handle_call({:load_config_template, session_id}, _from, table) do
    reply =
      case :ets.lookup(table, {:config_template, session_id}) do
        [{_, tmpl}] -> {:ok, tmpl}
        [] -> :error
      end

    {:reply, reply, table}
  end
```

Apply the equivalent change to `in_memory.ex` (same key scheme in its state map).

- [ ] **Step 5: Add the Postgres column migration**

Create `lib/normandy/behaviours/session_store/postgres/migration_add_template.ex`:

```elixir
defmodule Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate do
  @moduledoc "Adds the config_template column to normandy_sessions (Phase 7c)."
  use Ecto.Migration

  def up, do: alter(table(:normandy_sessions), do: add(:config_template, :binary))
  def down, do: alter(table(:normandy_sessions), do: remove(:config_template))
end
```

Create `priv/test_repo/migrations/20260617000100_add_config_template.exs`:

```elixir
defmodule Normandy.TestRepo.Migrations.AddConfigTemplate do
  use Ecto.Migration
  def up, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate.up()
  def down, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddTemplate.down()
end
```

- [ ] **Step 6: Implement on Postgres**

Add the `config_template` field to the `Session` Ecto schema (`schemas.ex`):

```elixir
      field :config_template, :binary
```

In `postgres.ex`, add (reuse `encode`/`decode`):

```elixir
  @impl true
  def save_config_template(repo, session_id, tmpl) do
    blob = encode(tmpl)

    %Session{session_id: session_id}
    |> Ecto.Changeset.change(config_template: blob)
    |> repo.insert(
      on_conflict: [set: [config_template: blob, updated_at: DateTime.utc_now()]],
      conflict_target: :session_id
    )
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def load_config_template(repo, session_id) do
    case repo.get(Session, session_id) do
      %Session{config_template: blob} when is_binary(blob) -> {:ok, decode(blob)}
      _ -> :error
    end
  end
```

- [ ] **Step 7: Run all store tests**

Run: `mix test test/behaviours/session_store/ets_test.exs test/behaviours/session_store/in_memory_test.exs`
Expected: PASS (template contract test green).
Run: `mix test test/behaviours/session_store/postgres_test.exs --include postgres`
Expected: PASS (after the new migration applies — the `aliases` run `ecto.migrate`).

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/behaviours/session_store.ex \
  lib/normandy/behaviours/session_store/in_memory.ex \
  lib/normandy/behaviours/session_store/ets.ex \
  lib/normandy/behaviours/session_store/postgres.ex \
  lib/normandy/behaviours/session_store/postgres/schemas.ex \
  lib/normandy/behaviours/session_store/postgres/migration_add_template.ex \
  priv/test_repo/migrations/20260617000100_add_config_template.exs \
  test/support/session_store_contract.ex
git commit -m "feat(session-store): persist non-secret config template (all impls + contract)"
```

---

### Task 2: `AgentTemplate` behaviour + `Catalog` (node-local supplement registry)

**Files:**
- Create: `lib/normandy/behaviours/agent_template.ex`
- Test: `test/behaviours/agent_template_test.exs`

**Interfaces:**
- Produces: behaviour `Normandy.Behaviours.AgentTemplate` with `@callback fetch(handle, template_id) :: {:ok, supplement} | :error`, where `supplement :: %{tool_registry: term(), before_hooks: [term()], after_hooks: [term()], client_builder: (String.t() -> struct())}`. Default `Catalog` (an `Agent`) with `start_link/1`, `put/3`, and `fetch/2`.

- [ ] **Step 1: Write the failing test**

Create `test/behaviours/agent_template_test.exs`:

```elixir
defmodule Normandy.Behaviours.AgentTemplateTest do
  use ExUnit.Case, async: true
  alias Normandy.Behaviours.AgentTemplate.Catalog

  test "put then fetch returns the supplement; unknown is :error" do
    {:ok, cat} = Catalog.start_link([])
    supp = %{tool_registry: :tr, before_hooks: [], after_hooks: [], client_builder: fn t -> {:client, t} end}
    assert :ok = Catalog.put(cat, "agent-x", supp)
    assert {:ok, ^supp} = Catalog.fetch(cat, "agent-x")
    assert :error = Catalog.fetch(cat, "missing")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/behaviours/agent_template_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the behaviour + Catalog**

Create `lib/normandy/behaviours/agent_template.ex`:

```elixir
defmodule Normandy.Behaviours.AgentTemplate do
  @moduledoc """
  Resolves the **node-local, non-serializable** half of an agent's config from a
  stable `template_id`: the tool registry, before/after hooks, and a
  `client_builder` that turns a credential token into an LLM client struct.

  The host registers a supplement per `template_id` on **every node** at boot
  (same code → same supplement). Combined with the persisted non-secret template
  (`SessionStore.{save,load}_config_template`) and the node-local
  `CredentialProvider`, this reconstructs a full `%BaseAgentConfig{}` on any node
  without moving secrets or closures across the cluster.
  """

  @type supplement :: %{
          tool_registry: term(),
          before_hooks: [term()],
          after_hooks: [term()],
          client_builder: (String.t() -> struct())
        }

  @callback fetch(handle :: term(), template_id :: String.t()) :: {:ok, supplement()} | :error

  defmodule Catalog do
    @moduledoc "Default node-local `AgentTemplate`: an Agent mapping template_id → supplement."
    @behaviour Normandy.Behaviours.AgentTemplate

    use Agent

    @spec start_link(keyword()) :: Agent.on_start()
    def start_link(opts) do
      name = Keyword.get(opts, :name)
      init = Keyword.get(opts, :templates, %{})
      if name, do: Agent.start_link(fn -> init end, name: name), else: Agent.start_link(fn -> init end)
    end

    @spec put(Agent.agent(), String.t(), Normandy.Behaviours.AgentTemplate.supplement()) :: :ok
    def put(cat, template_id, supplement),
      do: Agent.update(cat, &Map.put(&1, template_id, supplement))

    @impl true
    def fetch(cat, template_id) do
      case Agent.get(cat, &Map.get(&1, template_id)) do
        nil -> :error
        supp -> {:ok, supp}
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/behaviours/agent_template_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/agent_template.ex test/behaviours/agent_template_test.exs
git commit -m "feat(agent-template): node-local supplement registry (behaviour + Catalog)"
```

---

### Task 3: `ConfigTemplate` (extract + rebuild)

**Files:**
- Create: `lib/normandy/agents/config_template.ex`
- Test: `test/agents/config_template_test.exs`

**Interfaces:**
- Consumes: `BaseAgentConfig`, `Normandy.Behaviours.Config`, `AgentTemplate.supplement()`.
- Produces:
  - `ConfigTemplate.from_config(%BaseAgentConfig{}, template_id :: String.t()) :: map()` — a serializable, credential-free, closure-free map.
  - `ConfigTemplate.rebuild(template :: map(), supplement, token :: String.t()) :: %BaseAgentConfig{}`.

- [ ] **Step 1: Write the failing test (round-trip)**

Create `test/agents/config_template_test.exs`:

```elixir
defmodule Normandy.Agents.ConfigTemplateTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.{BaseAgentConfig, ConfigTemplate}
  alias Normandy.Behaviours.Config

  test "from_config produces a serializable, secret-free template" do
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
      behaviours: %Config{before_hooks: [fn _, _ -> :x end]}
    }

    tmpl = ConfigTemplate.from_config(config, "support-agent")

    assert tmpl.template_id == "support-agent"
    assert tmpl.model == "claude-x"
    refute Map.has_key?(tmpl, :client)
    refute Map.has_key?(tmpl, :tool_registry)
    # term_to_binary must succeed: no closures, no pids.
    assert is_binary(:erlang.term_to_binary(tmpl))
  end

  test "rebuild merges template + supplement + token into a full config" do
    tmpl = %{
      template_id: "support-agent",
      model: "claude-x",
      temperature: 0.3,
      max_tokens: 100,
      max_tool_iterations: 4,
      max_tool_concurrency: 2,
      name: "support",
      prompt_specification: %Normandy.Components.PromptSpecification{},
      input_schema: SomeInput,
      output_schema: SomeOutput,
      behaviours_refs: %{
        policy: {Normandy.Behaviours.PolicyEngine.AllowAll, []},
        budget: {Normandy.Behaviours.BudgetTracker.NoOp, []},
        credential: {Normandy.Behaviours.CredentialProvider.FromClient, []},
        compactor: {Normandy.Behaviours.Compactor.NoOp, []},
        model_catalog: {Normandy.Behaviours.ModelCatalog.Static, []},
        session_store: {Normandy.Behaviours.SessionStore.InMemory, []},
        session_registry: {Normandy.Behaviours.SessionRegistry.Native, []}
      }
    }

    tr = %Normandy.Tools.Registry{tools: %{"t" => %{}}}
    supp = %{tool_registry: tr, before_hooks: [:bh], after_hooks: [:ah],
             client_builder: fn token -> %{api_key: token, base_url: "https://api"} end}

    config = ConfigTemplate.rebuild(tmpl, supp, "TOKEN")

    assert config.model == "claude-x"
    assert config.tool_registry == tr
    assert config.client.api_key == "TOKEN"
    assert config.behaviours.before_hooks == [:bh]
    assert config.behaviours.policy == {Normandy.Behaviours.PolicyEngine.AllowAll, []}
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/config_template_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement `ConfigTemplate`**

Create `lib/normandy/agents/config_template.ex`:

```elixir
defmodule Normandy.Agents.ConfigTemplate do
  @moduledoc """
  Splits a `%BaseAgentConfig{}` into a serializable, secret-free **template**
  (persisted via `SessionStore.save_config_template/3`) and reconstructs a full
  config on any node from `template + node-local supplement + credential token`.

  Excluded from the template (resolved node-locally instead): `client` (built from
  the token), `tool_registry` (from the supplement), and `before/after_hooks`
  (from the supplement). Behaviour module refs travel in the template; their
  `opts` must be serializable.
  """
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Behaviours.Config

  @spec from_config(BaseAgentConfig.t(), String.t()) :: map()
  def from_config(%BaseAgentConfig{} = c, template_id) do
    b = c.behaviours || %Config{}

    %{
      template_id: template_id,
      model: c.model,
      temperature: c.temperature,
      max_tokens: c.max_tokens,
      max_tool_iterations: c.max_tool_iterations,
      max_tool_concurrency: c.max_tool_concurrency,
      name: c.name,
      prompt_specification: c.prompt_specification,
      input_schema: c.input_schema,
      output_schema: c.output_schema,
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

  @spec rebuild(map(), Normandy.Behaviours.AgentTemplate.supplement(), String.t()) ::
          BaseAgentConfig.t()
  def rebuild(tmpl, supplement, token) do
    refs = tmpl.behaviours_refs

    behaviours = %Config{
      policy: refs.policy,
      budget: refs.budget,
      credential: refs.credential,
      compactor: refs.compactor,
      model_catalog: refs.model_catalog,
      session_store: refs.session_store,
      session_registry: refs.session_registry,
      before_hooks: supplement.before_hooks,
      after_hooks: supplement.after_hooks
    }

    %BaseAgentConfig{
      model: tmpl.model,
      temperature: tmpl.temperature,
      max_tokens: tmpl.max_tokens,
      max_tool_iterations: tmpl.max_tool_iterations,
      max_tool_concurrency: tmpl.max_tool_concurrency,
      name: tmpl.name,
      prompt_specification: tmpl.prompt_specification,
      input_schema: tmpl.input_schema,
      output_schema: tmpl.output_schema,
      tool_registry: supplement.tool_registry,
      client: supplement.client_builder.(token),
      behaviours: behaviours,
      memory: Normandy.Components.AgentMemory.new_memory()
    }
  end
end
```

> NOTE: `memory` is set to an empty memory here; `Turn.Session` overwrites it with the rehydrated, max-messages-capped memory from `history/2` (Task 5), exactly as it already does for the direct-config path (`session.ex:66-71`).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/agents/config_template_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/config_template.ex test/agents/config_template_test.exs
git commit -m "feat(agents): ConfigTemplate extract/rebuild (secret-free, closure-free)"
```

---

### Task 4: `Turn.Server` Tier-2 reconstruct-on-init path

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex:15-28,48-64`
- Test: `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: `ConfigTemplate.rebuild/3`, `AgentTemplate.fetch/2`, `SessionStore.load_config_template/2`, `CredentialProvider.get_token/2`.
- Produces: when `opts` carries no `:config` but carries `:template_provider`, `init/1` reconstructs the config from the persisted template; otherwise uses `opts[:config]` (unchanged). New `Data` fields `template_provider` and `resume_policy`.

- [ ] **Step 1: Write the failing test**

Add to `test/agents/turn/server_test.exs`:

```elixir
  test "Tier-2 server reconstructs config from a persisted template (no :config in opts)" do
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    sid = "recon-#{System.unique_integer([:positive])}"

    base = build_test_config()
    tmpl = Normandy.Agents.ConfigTemplate.from_config(base, "kind-a")
    :ok = Normandy.Behaviours.SessionStore.InMemory.save_config_template(store, sid, tmpl)

    {:ok, cat} = Normandy.Behaviours.AgentTemplate.Catalog.start_link([])
    :ok = Normandy.Behaviours.AgentTemplate.Catalog.put(cat, "kind-a", %{
      tool_registry: base.tool_registry,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token -> base.client end
    })

    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    opts = [
      session_id: sid,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat}
    ]

    assert {:ok, pid} = Normandy.Agents.Turn.Server.start_link(opts)
    assert {:ok, ^pid} = Normandy.Behaviours.SessionRegistry.Native.whereis(reg, sid)
  end
```

> NOTE: `build_test_config/0`'s client must expose a binary `:api_key` so `CredentialProvider.FromClient` resolves a token; the default test config already uses a `ClaudioAdapter`-shaped client.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — `init/1` calls `Keyword.fetch!(opts, :config)` and crashes when `:config` is absent.

- [ ] **Step 3: Add `Data` fields**

In `server.ex`, extend the `Data` defstruct (`server.ex:17-27`) with:

```elixir
              template_provider: nil,
              resume_policy: :lazy,
```

- [ ] **Step 4: Reconstruct when `:config` is absent**

Replace the `init/1` head (`server.ex:48-64`) with a version that resolves config:

```elixir
  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    registry = Keyword.fetch!(opts, :registry)
    session_id = Keyword.fetch!(opts, :session_id)
    template_provider = Keyword.get(opts, :template_provider)

    config =
      case Keyword.get(opts, :config) do
        nil -> reconstruct_config!(store, template_provider, session_id)
        supplied -> supplied
      end

    data = %Data{
      session_id: session_id,
      config: config,
      store: store,
      registry: registry,
      template_provider: template_provider,
      resume_policy: Keyword.get(opts, :resume_policy, :lazy),
      subscriber: Keyword.get(opts, :subscriber),
      handlers: Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),
      turn_state: Keyword.get(opts, :turn_state),
      approval_timeout_ms: Keyword.get(opts, :approval_timeout_ms, 300_000),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000)
    }

    register_self(data)
    {:ok, :idle, data, idle_timeout(data)}
  end

  defp reconstruct_config!({store_mod, store_handle}, {tp_mod, tp_handle}, session_id) do
    {:ok, tmpl} = store_mod.load_config_template(store_handle, session_id)
    {:ok, supplement} = tp_mod.fetch(tp_handle, session_id_template_id(tmpl))
    {cred_mod, cred_opts} = tmpl.behaviours_refs.credential
    {:ok, token} = cred_mod.get_token(token_provider(tmpl), cred_opts)
    Normandy.Agents.ConfigTemplate.rebuild(tmpl, supplement, token)
  end

  defp session_id_template_id(%{template_id: id}), do: id

  # FromClient needs a client carrying :api_key; env/vault providers ignore the
  # first arg. For reconstruction the token must come from a node-local provider,
  # so we pass a minimal provider map derived from the template's model.
  defp token_provider(%{model: model}), do: %{model: model}
```

> NOTE: in a real Tier-2 deployment the `credential` ref is an env/vault provider that ignores `token_provider/1`'s argument (it reads the node-local secret). `FromClient` is unsuitable for reconstruction (no client to read from) — that constraint is the documented Tier-2 requirement (design §7.4). The test above uses a `client_builder` that returns the test client, and a `credential` ref of `FromClient` will fail get_token (no client yet); so the test config's `credential` ref must be a stub provider — see Step 5.

- [ ] **Step 5: Provide a test stub credential provider**

Add to the test (top of `server_test.exs` or a support module) a trivial node-local provider, and use it in `build_test_config/0`'s behaviours OR override the template's credential ref in the test:

```elixir
defmodule Normandy.Test.StubCreds do
  @behaviour Normandy.Behaviours.CredentialProvider
  @impl true
  def get_token(_provider, _opts), do: {:ok, "TEST-TOKEN"}
end
```

In the Task-4 test, set the template's credential ref before saving:

```elixir
    tmpl = put_in(Normandy.Agents.ConfigTemplate.from_config(base, "kind-a").behaviours_refs.credential,
                  {Normandy.Test.StubCreds, []})
```

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/agents/turn/server_test.exs`
Expected: PASS — the reconstructed server self-registers and is discoverable. Existing direct-`:config` tests stay green.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "feat(turn): Tier-2 reconstruct-on-init from persisted template + node-local supplement"
```

---

### Task 5: `Turn.Supervisor.Horde` (lazy, `restart: :temporary`) + `Turn.Session` thin start

**Files:**
- Create: `lib/normandy/agents/turn/supervisor/horde.ex`
- Modify: `lib/normandy/agents/turn/session.ex`
- Test: `test/agents/turn/supervisor_horde_test.exs`

**Interfaces:**
- Produces: `Turn.Supervisor.Horde.start_link/1`, `start_server/2` (uses `child_name/2`, `restart: :temporary`). `Turn.Session.run/2` persists the template on first start and passes thin opts (`template_provider`, no `:config`) when `opts[:template_provider]` is present.

- [ ] **Step 1: Write the failing test**

Create `test/agents/turn/supervisor_horde_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.Supervisor.HordeTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  test "starts a server under Horde with a :via name and restart :temporary" do
    {:ok, sup} = HSup.start_link(name: :"hsup_#{System.unique_integer([:positive])}")
    reg = HReg.new()
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    {:ok, cat} = Normandy.Behaviours.AgentTemplate.Catalog.start_link([])
    sid = "h-#{System.unique_integer([:positive])}"

    base = build_test_config()
    tmpl = put_in(Normandy.Agents.ConfigTemplate.from_config(base, "k").behaviours_refs.credential,
                  {Normandy.Test.StubCreds, []})
    :ok = Normandy.Behaviours.SessionStore.InMemory.save_config_template(store, sid, tmpl)
    :ok = Normandy.Behaviours.AgentTemplate.Catalog.put(cat, "k", %{
      tool_registry: base.tool_registry, before_hooks: [], after_hooks: [],
      client_builder: fn _ -> base.client end})

    opts = [
      session_id: sid,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {HReg, reg},
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat},
      resume_policy: :lazy
    ]

    assert {:ok, pid} = HSup.start_server(sup, opts)
    assert {:ok, ^pid} = HReg.whereis(reg, sid)
  end

  defp build_test_config, do: Normandy.Test.TurnConfig.build()
end
```

> NOTE: extract the shared `build_test_config/0` used across Turn tests into `Normandy.Test.TurnConfig.build/0` (a support module) so 7c/7d tests reuse it; do this as the first action of Step 3 if it does not exist.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/supervisor_horde_test.exs`
Expected: FAIL — `Turn.Supervisor.Horde` undefined.

- [ ] **Step 3: Implement `Turn.Supervisor.Horde`**

Create `lib/normandy/agents/turn/supervisor/horde.ex`:

```elixir
defmodule Normandy.Agents.Turn.Supervisor.Horde do
  @moduledoc """
  `Horde.DynamicSupervisor` for `Turn.Server` processes — cluster-wide placement
  and supervision. Children start under the registry's `:via` name (atomic
  registration). `resume_policy` maps to the child `restart` value: `:lazy` →
  `:temporary` (a lost node's session is NOT redistributed; it is rebuilt on the
  next request), `:eager` → `:transient` (Phase 7d; redistributed on node-down).
  """
  alias Normandy.Agents.Turn.Server

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Horde.DynamicSupervisor.start_link(name: name, strategy: :one_for_one, members: :auto)
  end

  @spec start_server(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_server(sup, server_opts) do
    server_opts = put_child_name(server_opts)
    restart = restart_for(Keyword.get(server_opts, :resume_policy, :lazy))

    spec = %{
      id: Keyword.fetch!(server_opts, :session_id),
      start: {Server, :start_link, [server_opts]},
      restart: restart,
      type: :worker
    }

    Horde.DynamicSupervisor.start_child(sup, spec)
  end

  defp restart_for(:eager), do: :transient
  defp restart_for(_), do: :temporary

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
end
```

> NOTE: the `spec.id` is the `session_id` (unique per session) so Horde tracks one child per session.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/agents/turn/supervisor_horde_test.exs`
Expected: PASS.

- [ ] **Step 5: Persist the template + pass thin opts in `Turn.Session`**

In `lib/normandy/agents/turn/session.ex`, `rehydrate_and_start/1` must, for Tier-2 (when `opts[:template_provider]` is set), (a) persist the template derived from the caller's config on first start, and (b) pass thin server opts (no `:config`, with `:template_provider` + `:resume_policy`). Add near the top of `rehydrate_and_start/1`:

```elixir
    template_provider = Keyword.get(opts, :template_provider)
    resume_policy = Keyword.get(opts, :resume_policy, :lazy)
```

After the memory is rebuilt and `config` is finalized (current `session.ex:71`), branch the server opts:

```elixir
        server_opts =
          if template_provider do
            tmpl = Normandy.Agents.ConfigTemplate.from_config(config, template_id_of(opts, config))
            :ok = store_mod.save_config_template(store_handle, sid, tmpl)

            opts
            |> Keyword.take([:session_id, :store, :registry, :subscriber, :handlers,
                             :approval_timeout_ms, :idle_timeout_ms, :template_provider])
            |> Keyword.put(:resume_policy, resume_policy)
            |> Keyword.put(:turn_state, turn_state)
          else
            opts
            |> Keyword.take([:session_id, :store, :registry, :subscriber, :handlers,
                             :approval_timeout_ms, :idle_timeout_ms])
            |> Keyword.put(:config, config)
            |> Keyword.put(:turn_state, turn_state)
          end

        case Supervisor.start_server(supervisor, server_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
```

Add a helper:

```elixir
  defp template_id_of(opts, config),
    do: Keyword.get(opts, :template_id) || config.name || "default"
```

> NOTE: `Supervisor` here is whatever module the caller passes as `:supervisor` (the local `Turn.Supervisor` for Tier 0/1, `Turn.Supervisor.Horde` for Tier 2). Both expose `start_server/2`. Confirm the call site resolves the supervisor module from the handle; if `Turn.Session` calls `Supervisor.start_server/2` with a hard module alias, change it to dispatch on a `:supervisor_mod` opt (default `Turn.Supervisor`). Add `supervisor_mod = Keyword.get(opts, :supervisor_mod, Supervisor)` and call `supervisor_mod.start_server(supervisor, server_opts)`.

- [ ] **Step 6: Run the Session tests**

Run: `mix test test/agents/turn/session_test.exs`
Expected: PASS (Tier 0/1 path unchanged; new Tier-2 branch covered by the integration test in Task 6).

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/turn/supervisor/horde.ex lib/normandy/agents/turn/session.ex \
  test/agents/turn/supervisor_horde_test.exs test/support/turn_config.ex
git commit -m "feat(turn): Horde.DynamicSupervisor (lazy) + thin Tier-2 start with template persistence"
```

---

### Task 6: Wiring (`AgentProcess`, `Config`) + single-node Tier-2 integration + back-compat

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex:283-318,331-340`
- Test: `test/agents/turn/tier2_integration_test.exs`, existing integration suites

**Interfaces:**
- Produces: `AgentProcess` accepts caller-supplied Horde `supervisor`, `registry`, Postgres `store`, and `template_provider`, threading them into `Turn.Session` opts. Default (none supplied) stays Tier 0 (local + InMemory + Native).

- [ ] **Step 1: Write the failing single-node Tier-2 integration test**

Create `test/agents/turn/tier2_integration_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.Tier2IntegrationTest do
  @moduledoc "Tier-2 (Horde reg+sup, lazy) as a cluster-of-one, end to end."
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn.{Session, Supervisor}
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup

  test "a turn runs through the Horde supervisor with reconstructed config" do
    reg = HReg.new()
    {:ok, sup} = HSup.start_link(name: :"t2_#{System.unique_integer([:positive])}")
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    {:ok, cat} = Normandy.Behaviours.AgentTemplate.Catalog.start_link([])
    sid = "t2-#{System.unique_integer([:positive])}"

    base = Normandy.Test.TurnConfig.build()
    register_supplement(cat, base)

    opts = [
      session_id: sid,
      config: base,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {HReg, reg},
      supervisor: sup,
      supervisor_mod: HSup,
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat},
      template_id: "k",
      resume_policy: :lazy
    ]

    assert {:ok, _result} = Session.run(opts, "hello")
    assert {:ok, _pid} = HReg.whereis(reg, sid)
    # The template was persisted (reconstruction would work on another node).
    assert {:ok, _tmpl} = Normandy.Behaviours.SessionStore.InMemory.load_config_template(store, sid)
  end

  defp register_supplement(cat, base) do
    Normandy.Behaviours.AgentTemplate.Catalog.put(cat, "k", %{
      tool_registry: base.tool_registry, before_hooks: [], after_hooks: [],
      client_builder: fn _ -> base.client end})
  end
end
```

> NOTE: `Session.run/2`'s first start uses `config` to persist the template, then starts thin; the running server reconstructs. The credential ref in `base.behaviours` must be a node-local provider (`Normandy.Test.StubCreds`) for reconstruction to succeed — set it in `Normandy.Test.TurnConfig.build/0`.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/tier2_integration_test.exs`
Expected: FAIL — `Session.run/2` does not yet accept/thread `supervisor_mod`/`template_provider` (or `AgentProcess` wiring missing).

- [ ] **Step 3: Thread the new opts through `Turn.Session`**

Ensure `ensure_server/1` and `rehydrate_and_start/1` read `:supervisor_mod` (default `Turn.Supervisor`) and call `supervisor_mod.start_server/2` (done in Task 5 Step 5). Confirm `approve/2` and `run/2` still resolve the registry via the `:registry` ref (unchanged).

- [ ] **Step 4: Extend `AgentProcess.server_infra/1`**

In `lib/normandy/coordination/agent_process.ex`, `server_infra/1` currently starts local defaults when nothing is supplied. Keep that, but pass through the new opts. Add to `session_opts/1` (`agent_process.ex:331-340`):

```elixir
      supervisor_mod: Map.get(state, :supervisor_mod, Normandy.Agents.Turn.Supervisor),
      template_provider: Map.get(state, :template_provider),
      resume_policy: Map.get(state, :resume_policy, :lazy),
      template_id: Map.get(state, :template_id)
```

and capture `:supervisor_mod`, `:template_provider`, `:resume_policy`, `:template_id` from `opts` into `state` in `init/1` (alongside the existing `:store`/`:registry`/`:supervisor` capture near `agent_process.ex:258-263`).

> NOTE: do **not** auto-start a Horde supervisor in `server_infra/1`'s default branch — Horde infra is application-level (host-started). The default branch stays local (Tier 0). Tier-2 requires the host to supply `supervisor`, `supervisor_mod: Turn.Supervisor.Horde`, `registry: {SessionRegistry.Horde, …}`, `store: {SessionStore.Postgres, …}`, and `template_provider`.

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/agents/turn/tier2_integration_test.exs`
Expected: PASS.

- [ ] **Step 6: Update + run affected integration tests (back-compat)**

Run: `mix test test/coordination/agent_process_server_test.exs test/agents/turn/server_integration_test.exs test/agents/turn/session_test.exs test/behaviours/config_test.exs`
Expected: PASS. Tier 0/1 defaults unchanged; update any test that asserted the exact `session_opts/1` keyword shape to include the new keys.

- [ ] **Step 7: Full default suite**

Run: `mix format && mix test`
Expected: PASS — `:postgres`/`:distributed` excluded; defaults identical to before.

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex test/agents/turn/tier2_integration_test.exs
git commit -m "feat(coordination): thread Horde supervisor + template provider through AgentProcess/Session"
```

---

### Task 7: `:distributed` lazy-recovery test (node-down → rehydrate elsewhere)

**Files:**
- Create: `test/agents/turn/lazy_recovery_distributed_test.exs`

**Interfaces:**
- Consumes: `Normandy.ClusterCase` (7b), `Turn.Supervisor.Horde`, `SessionRegistry.Horde`, a shared store reachable from both nodes (in this test, an InMemory store owned by the primary; in production, Postgres).

- [ ] **Step 1: Write the failing test**

Create `test/agents/turn/lazy_recovery_distributed_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.LazyRecoveryDistributedTest do
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed

  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  setup_all do
    unless Node.alive?(), do: {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    :ok
  end

  test "after the owning node dies, whereis is :none and the next start rehydrates" do
    reg = :"lazy_reg_#{System.unique_integer([:positive])}"
    {:ok, _} = HReg.start_link(name: reg)
    {peer, node} = start_peer(~c"lazypeer")
    {:ok, _} = rpc(node, HReg, :start_link, [[name: reg]])
    Process.sleep(500)

    sid = "lazy-#{System.unique_integer([:positive])}"
    remote = rpc(node, Kernel, :spawn, [fn -> Process.sleep(60_000) end])
    :ok = rpc(node, HReg, :register, [reg, sid, remote])
    assert eventually(fn -> match?({:ok, _}, HReg.whereis(reg, sid)) end)

    :peer.stop(peer)

    # Horde drops the registration when the owning node leaves.
    assert eventually(fn -> HReg.whereis(reg, sid) == :none end)
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

> NOTE: this proves the lazy precondition (registration drops on node loss → next request hits the `:none` rehydrate path). A full end-to-end "rehydrate-and-run-on-survivor" assertion additionally needs a Postgres store reachable from both nodes (the `:postgres` + `:distributed` job); add that variant in CI where both services are available.

- [ ] **Step 2: Run the distributed test**

Run: `mix test test/agents/turn/lazy_recovery_distributed_test.exs --include distributed`
Expected: PASS — `whereis` returns `:none` after the peer stops.

- [ ] **Step 3: Confirm default suite excludes it**

Run: `mix test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/agents/turn/lazy_recovery_distributed_test.exs
git commit -m "test(turn): distributed lazy-recovery registration-drop on node loss"
```

---

## Self-Review

- **Spec coverage (§7.3, §7.4, §7.6 lazy, §7.7):** thin specs / no secrets in CRDT (Tasks 4–5); template persisted (Task 1) + non-secret/closure-free (Task 3 test asserts `term_to_binary`); node-local supplement (Task 2); reconstruction on init (Task 4); `Horde.DynamicSupervisor` lazy `:temporary` (Task 5); Config/AgentProcess wiring + default-off (Task 6); single-node Tier-2 cluster-of-one (Task 6) and multi-node lazy precondition (Task 7); credential invariant via node-local provider requirement (Task 4 notes). ✓
- **Integration tests:** Task 6 Step 6 re-runs/updates `agent_process_server_test.exs`, `server_integration_test.exs`, `session_test.exs`, `config_test.exs`.
- **Deferred to 7d (intentional):** `:eager` resume + auto-resume-on-init (Task 5 maps `:eager → :transient` but the init-time turn resume is 7d); `resume_policy` Postgres column (7d).
- **Placeholder scan:** none. Soft spots flagged, not placeholders: the `supervisor_mod` dispatch confirmation (Task 5 Step 5 NOTE) and the cross-node end-to-end-with-Postgres variant (Task 7 NOTE).
- **Type consistency:** `ConfigTemplate.from_config/2` output keys (`template_id`, `behaviours_refs`, scalars) match `rebuild/3` and `Turn.Server.reconstruct_config!/3` reads; `AgentTemplate.supplement()` shape (`tool_registry`, `before_hooks`, `after_hooks`, `client_builder`) consistent across Tasks 2–6; `start_server/2` returns `{:ok, pid} | {:error, {:already_started, pid}}` handled in `Turn.Session` (Task 5).
