# Autoresume Demo — Distributed Node-Kill Handoff — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable demo (its own mix app under `examples/`) where real Claude-powered agents on a local multi-node BEAM cluster survive a full node kill — the `ResumeReaper` reconstructs and resumes them on a surviving node — visualized live on a small web dashboard.

**Architecture:** A separate `examples/autoresume_demo` mix app depends on Normandy via a `path:` dep and owns all its own deps, so the library's dependency tree is untouched. An observer node spawns N worker `:peer` nodes; agents run as durable `Turn.Server` sessions (eager, Tier-2) under a Horde supervisor with shared Postgres state. Killing a worker triggers the `ResumeReaper` on a survivor to reconstruct the agent from Postgres + a node-local `Catalog` supplement + an env credential provider. A `DemoCollector` on the observer polls the Postgres store + Horde registry (the same durable state the resume mechanism uses) and pushes per-agent state to the browser over SSE. Real-vs-simulated LLM is switched at the **client** level via the `client_builder` closure (the only seam carried through Tier-2 reconstruction), so simulated mode reproduces the entire mechanic offline and deterministically.

**Tech Stack:** Elixir, Normandy (path dep), Horde (distributed registry/supervisor), Ecto + Postgrex (Postgres session store), Bandit + Plug (web dashboard + SSE), Jason, `:peer` (cluster), real Claudio/Anthropic via `Normandy.LLM.ClaudioAdapter`.

## Global Constraints

- The Normandy library's `mix.exs` deps MUST NOT change. All demo deps live in `examples/autoresume_demo/mix.exs`. (Acceptance criterion 7 of the spec.)
- Cross-node store is **Postgres only**; registry is **Horde**. No Redis/Mnesia variants.
- `DEMO_MODE` env: `real` (default) or `simulated`. **No silent fallback** — if `real` is selected and `ANTHROPIC_API_KEY` is absent, fail loudly at boot. `simulated` runs the identical flow with no network.
- The single real/sim switch is the `client_builder` closure in `AutoresumeDemo.Agent`. Do not branch on mode anywhere in the per-node wiring.
- Demo lives entirely under `examples/autoresume_demo/`. Run all `mix` commands from that directory.
- Commit messages: conventional-commits style (e.g. `feat(demo): …`), matching this repo. No AI attribution in commits.
- Postgres connection defaults (overridable by env): host `localhost`, port `5432`, user `postgres`, password `postgres`, database `autoresume_demo`. `docker-compose.verify.yml` at the repo root already exposes a compatible Postgres.
- Model id is configurable via `DEMO_MODEL`, default `"claude-3-5-sonnet-20241022"` (the id the existing `examples/customer_support_app` uses with Claudio 0.5.0). May be overridden to a newer id the account/Claudio version supports.

## Verified API surface (ground truth — do not re-derive)

These were confirmed against the codebase. Use them verbatim.

- Postgres store handle: `{Normandy.Behaviours.SessionStore.Postgres, AutoresumeDemo.Repo}`.
- `normandy_sessions` columns: `session_id` (pk, text), `head_id` (binary_id), `current_turn_id` (text), `turn_state` (binary), `config_template` (binary), `resume_policy` (text), `inserted_at`/`updated_at` (utc_datetime_usec). `normandy_session_entries`: `id` (pk binary_id), `parent_id` (binary_id), `turn_id` (text), `role` (text), `content` (binary), `inserted_at` (utc_datetime_usec).
- `Normandy.Behaviours.AgentTemplate.Catalog.start_link(name: NAME, templates: %{})`; `Catalog.put(name_or_pid, template_id, supplement)`; supplement keys: `tool_registry`, `before_hooks`, `after_hooks`, `client_builder` (`(String.t() -> struct())`).
- `Normandy.Agents.ConfigTemplate.from_config(%BaseAgentConfig{}, template_id, :eager)` → map with a `behaviours_refs` map (keys include `:credential`, sourced from `config.behaviours.credential`). `rebuild/3` does `client: supplement.client_builder.(token)`.
- `Normandy.Behaviours.SessionRegistry.Horde.start_link(name: NAME)`; `whereis(NAME, sid) :: {:ok, pid} | :none`.
- `Normandy.Agents.Turn.Supervisor.Horde.start_link(name: NAME)`; `start_server(NAME, opts)`.
- `Normandy.Agents.Turn.ResumeReaper.start_link(store:, registry:, supervisor:, supervisor_mod:, template_provider:)`.
- `Normandy.Agents.Turn.Session.run(opts, user_input) :: {:ok, term} | {:error, term}`. Eager-session opts: `session_id, config, store, registry, supervisor, supervisor_mod, template_provider, template_id, resume_policy: :eager`. (Omit `:handlers` — `Turn.Server` defaults to `BaseAgent.non_streaming_handlers()`, which calls `Model.converse(config.client, …)`.)
- `Normandy.Tools.BaseTool` protocol callbacks: `tool_name/1`, `tool_description/1`, `input_schema/1` (returns a JSON-schema map), `run/1` → `{:ok, term} | {:error, String.t}`. `Normandy.Tools.Registry.new([%Tool{}])`.
- `Normandy.Agents.Model` protocol: `converse(config, model, temperature, max_tokens, messages, response_model, opts \\ []) :: struct() | {struct(), map() | nil}`; also `completitions/6` (note the spelling). For tool turns, return `%Normandy.Agents.ToolCallResponse{content: String, tool_calls: [%Normandy.Components.ToolCall{id, name, input}]}`. Non-empty `tool_calls` drives another iteration; `[]` finalizes.
- Real client struct: `%Normandy.LLM.ClaudioAdapter{api_key: token, options: %{timeout: 60_000}}`.
- `:peer.start_link(%{name: ~c"name", host: ~c"127.0.0.1", args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]})` then `:erpc.call(node, :code, :add_paths, [:code.get_path()])`.

---

### Task 1: Scaffold the `examples/autoresume_demo` mix app

**Files:**
- Create: `examples/autoresume_demo/mix.exs`
- Create: `examples/autoresume_demo/.formatter.exs`
- Create: `examples/autoresume_demo/.gitignore`
- Create: `examples/autoresume_demo/config/config.exs`
- Create: `examples/autoresume_demo/lib/autoresume_demo/application.ex` (minimal placeholder; expanded in Task 7)

**Interfaces:**
- Produces: the `:autoresume_demo` app, `AutoresumeDemo.Application` (OTP entry), app-env keys `:demo_mode`, `:demo_model`, `:dashboard_port`, `:worker_node_count`, `:sim_step_delay_ms`, `:role`.

- [ ] **Step 1: Create `mix.exs`**

```elixir
defmodule AutoresumeDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :autoresume_demo,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [mod: {AutoresumeDemo.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Normandy declares horde/ecto_sql/postgrex as OPTIONAL, so the demo must
  # declare them itself to pull them into the dependency tree.
  defp deps do
    [
      {:normandy, path: "../.."},
      {:horde, "~> 0.9"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
```

- [ ] **Step 2: Create `.formatter.exs`**

```elixir
[inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]
```

- [ ] **Step 3: Create `.gitignore`**

```
/_build/
/deps/
/cover/
erl_crash.dump
*.ez
```

- [ ] **Step 4: Create `config/config.exs`**

```elixir
import Config

config :autoresume_demo, ecto_repos: [AutoresumeDemo.Repo]

config :autoresume_demo, AutoresumeDemo.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: System.get_env("POSTGRES_DB", "autoresume_demo"),
  pool_size: 10

config :autoresume_demo,
  role: String.to_atom(System.get_env("DEMO_ROLE", "observer")),
  demo_mode: String.to_atom(System.get_env("DEMO_MODE", "real")),
  demo_model: System.get_env("DEMO_MODEL", "claude-3-5-sonnet-20241022"),
  dashboard_port: String.to_integer(System.get_env("DASHBOARD_PORT", "4000")),
  worker_node_count: String.to_integer(System.get_env("WORKER_NODES", "3")),
  sim_step_delay_ms: String.to_integer(System.get_env("SIM_STEP_DELAY_MS", "1500"))
```

- [ ] **Step 5: Create a minimal `lib/autoresume_demo/application.ex` (placeholder, expanded in Task 7)**

```elixir
defmodule AutoresumeDemo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: AutoresumeDemo.Supervisor)
  end
end
```

- [ ] **Step 6: Fetch deps and compile**

Run: `cd examples/autoresume_demo && mix deps.get && mix compile`
Expected: deps resolve (normandy via path), compiles with no errors.

- [ ] **Step 7: Confirm the library's deps are untouched**

Run: `git -C ../.. diff --name-only -- mix.exs mix.lock`
Expected: NO output (the root `mix.exs`/`mix.lock` are unchanged).

- [ ] **Step 8: Commit**

```bash
git add examples/autoresume_demo/mix.exs examples/autoresume_demo/.formatter.exs examples/autoresume_demo/.gitignore examples/autoresume_demo/config/config.exs examples/autoresume_demo/lib/autoresume_demo/application.ex
git commit -m "feat(demo): scaffold autoresume_demo mix app"
```

---

### Task 2: Postgres Repo + migration (the cross-node session store schema)

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/repo.ex`
- Create: `examples/autoresume_demo/priv/repo/migrations/20260624000001_create_session_tables.exs`
- Test: `examples/autoresume_demo/test/store_test.exs`
- Modify: `examples/autoresume_demo/config/config.exs` (add `import_config "#{config_env()}.exs"` is NOT needed; test DB config below)
- Create: `examples/autoresume_demo/config/test.exs`
- Create: `examples/autoresume_demo/test/test_helper.exs`

**Interfaces:**
- Produces: `AutoresumeDemo.Repo`; the Postgres store handle `{Normandy.Behaviours.SessionStore.Postgres, AutoresumeDemo.Repo}` usable for `save_turn_state/3`, `load_turn_state/2`, `save_config_template/3`, `list_resumable/1`, `history/2`.

- [ ] **Step 1: Create `lib/autoresume_demo/repo.ex`**

```elixir
defmodule AutoresumeDemo.Repo do
  use Ecto.Repo, otp_app: :autoresume_demo, adapter: Ecto.Adapters.Postgres
end
```

- [ ] **Step 2: Create the migration `priv/repo/migrations/20260624000001_create_session_tables.exs`**

This mirrors Normandy's three Postgres migrations (base + add_template + add_resume_policy) combined. Column names MUST match Normandy's `Session` Ecto schema exactly.

```elixir
defmodule AutoresumeDemo.Repo.Migrations.CreateSessionTables do
  use Ecto.Migration

  def up do
    create table(:normandy_session_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:parent_id, :binary_id)
      add(:turn_id, :text)
      add(:role, :text)
      add(:content, :binary)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:normandy_session_entries, [:parent_id]))

    create table(:normandy_sessions, primary_key: false) do
      add(:session_id, :text, primary_key: true)
      add(:head_id, :binary_id)
      add(:current_turn_id, :text)
      add(:turn_state, :binary)
      add(:config_template, :binary)
      add(:resume_policy, :text)
      timestamps(type: :utc_datetime_usec)
    end
  end

  def down do
    drop(table(:normandy_sessions))
    drop(table(:normandy_session_entries))
  end
end
```

- [ ] **Step 3: Create `config/test.exs`** (use a separate DB; no sandbox — these are real cross-process writes)

```elixir
import Config

config :autoresume_demo, AutoresumeDemo.Repo,
  database: System.get_env("POSTGRES_DB", "autoresume_demo_test"),
  pool_size: 10

config :autoresume_demo, sim_step_delay_ms: 0
config :logger, level: :warning
```

- [ ] **Step 4: Make `config/config.exs` import the env config**

Append to `config/config.exs`:

```elixir
import_config "#{config_env()}.exs"
```

Create `examples/autoresume_demo/config/dev.exs` with a single line so dev boot works:

```elixir
import Config
```

- [ ] **Step 5: Create `test/test_helper.exs`** (start the Repo, run migrations once)

```elixir
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

_ = Ecto.Adapters.Postgres.storage_up(AutoresumeDemo.Repo.config())
{:ok, _} = AutoresumeDemo.Repo.start_link()
Ecto.Migrator.run(AutoresumeDemo.Repo, :up, all: true)

ExUnit.start()
```

- [ ] **Step 6: Write the failing test `test/store_test.exs`**

```elixir
defmodule AutoresumeDemo.StoreTest do
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Postgres, as: PG
  alias Normandy.Agents.Turn

  @store AutoresumeDemo.Repo

  test "save then load a non-terminal turn state round-trips" do
    sid = "store-test-#{System.unique_integer([:positive])}"
    :ok = PG.save_turn_state(@store, sid, %Turn.State{status: :steering, iterations_left: 3})

    assert {:ok, %Turn.State{status: :steering, iterations_left: 3}} =
             PG.load_turn_state(@store, sid)
  end

  test "an eager session shows up in list_resumable" do
    sid = "resumable-#{System.unique_integer([:positive])}"
    tmpl = %{template_id: "research", resume_policy: :eager}
    :ok = PG.save_config_template(@store, sid, tmpl)
    :ok = PG.save_turn_state(@store, sid, %Turn.State{status: :steering, iterations_left: 1})

    assert {:ok, sids} = PG.list_resumable(@store)
    assert sid in sids
  end
end
```

- [ ] **Step 7: Run to verify it fails (no DB / tables yet)**

Run: `docker compose -f ../../docker-compose.verify.yml up -d postgres && cd examples/autoresume_demo && MIX_ENV=test mix ecto.create && MIX_ENV=test mix test test/store_test.exs`

Note: if `mix ecto.create` is unavailable because the app isn't started, the `test_helper.exs` `storage_up` handles creation; running `mix test` is sufficient. Expected first run: FAIL (relation does not exist) until the migration runs via `test_helper.exs`. Then re-run.

- [ ] **Step 8: Run migrations & re-run the test**

Run: `MIX_ENV=test mix test test/store_test.exs`
Expected: PASS (both tests). `test_helper.exs` runs the migration on the test DB.

- [ ] **Step 9: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/repo.ex examples/autoresume_demo/priv/repo/migrations/20260624000001_create_session_tables.exs examples/autoresume_demo/config/test.exs examples/autoresume_demo/config/dev.exs examples/autoresume_demo/config/config.exs examples/autoresume_demo/test/test_helper.exs examples/autoresume_demo/test/store_test.exs
git commit -m "feat(demo): postgres repo + session store schema migration"
```

---

### Task 3: `EnvCredentialProvider` (node-local token source)

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/env_credential_provider.ex`
- Test: `examples/autoresume_demo/test/env_credential_provider_test.exs`

**Interfaces:**
- Produces: `AutoresumeDemo.EnvCredentialProvider` implementing `Normandy.Behaviours.CredentialProvider.get_token/2` → `{:ok, String.t()}` in real mode (from `ANTHROPIC_API_KEY`) and `{:ok, "SIMULATED-NO-KEY"}` in simulated mode when no key is present. Referenced in templates as `{AutoresumeDemo.EnvCredentialProvider, []}`.

Rationale: `reconstruct_config!` always calls `get_token`; it is fail-closed (raises on `{:error, _}`), which would make the reaper skip the session. So simulated mode must still yield a token (the `client_builder` ignores it).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AutoresumeDemo.EnvCredentialProviderTest do
  use ExUnit.Case, async: false

  alias AutoresumeDemo.EnvCredentialProvider, as: P

  setup do
    prev_key = System.get_env("ANTHROPIC_API_KEY")
    prev_mode = Application.get_env(:autoresume_demo, :demo_mode)
    on_exit(fn ->
      if prev_key, do: System.put_env("ANTHROPIC_API_KEY", prev_key), else: System.delete_env("ANTHROPIC_API_KEY")
      Application.put_env(:autoresume_demo, :demo_mode, prev_mode)
    end)
    :ok
  end

  test "returns the env key when present" do
    System.put_env("ANTHROPIC_API_KEY", "sk-test-123")
    assert {:ok, "sk-test-123"} = P.get_token(%{}, [])
  end

  test "returns a placeholder token in simulated mode when no key" do
    System.delete_env("ANTHROPIC_API_KEY")
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    assert {:ok, "SIMULATED-NO-KEY"} = P.get_token(%{}, [])
  end

  test "errors in real mode when no key" do
    System.delete_env("ANTHROPIC_API_KEY")
    Application.put_env(:autoresume_demo, :demo_mode, :real)
    assert {:error, :missing_anthropic_api_key} = P.get_token(%{}, [])
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test test/env_credential_provider_test.exs`
Expected: FAIL (module not defined).

- [ ] **Step 3: Implement `env_credential_provider.ex`**

```elixir
defmodule AutoresumeDemo.EnvCredentialProvider do
  @moduledoc """
  Node-local credential provider. Reads ANTHROPIC_API_KEY from the environment.
  In DEMO_MODE=simulated, returns a placeholder so Tier-2 reconstruction (which
  is fail-closed on a missing token) still proceeds — the SimClient ignores it.
  """
  @behaviour Normandy.Behaviours.CredentialProvider

  @impl true
  def get_token(_provider, _opts) do
    case {Application.get_env(:autoresume_demo, :demo_mode, :real),
          System.get_env("ANTHROPIC_API_KEY")} do
      {_mode, key} when is_binary(key) and key != "" -> {:ok, key}
      {:simulated, _} -> {:ok, "SIMULATED-NO-KEY"}
      _ -> {:error, :missing_anthropic_api_key}
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test test/env_credential_provider_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/env_credential_provider.ex examples/autoresume_demo/test/env_credential_provider_test.exs
git commit -m "feat(demo): env-based node-local credential provider"
```

---

### Task 4: `ResearchStep` tool (the deterministic per-step work)

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/tools/research_step.ex`
- Test: `examples/autoresume_demo/test/tools/research_step_test.exs`

**Interfaces:**
- Produces: `%AutoresumeDemo.Tools.ResearchStep{topic, n}` implementing `Normandy.Tools.BaseTool` with `tool_name/1 == "research_step"`, `run/1 -> {:ok, %{"step" => n, "finding" => String}}`. Consumed by `Normandy.Tools.Registry.new([%ResearchStep{}])` (Task 6) and invoked by the default `dispatch_tools` handler in both modes.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AutoresumeDemo.Tools.ResearchStepTest do
  use ExUnit.Case, async: true

  alias AutoresumeDemo.Tools.ResearchStep
  alias Normandy.Tools.BaseTool

  test "exposes name, description, and an object input schema" do
    t = %ResearchStep{}
    assert BaseTool.tool_name(t) == "research_step"
    assert is_binary(BaseTool.tool_description(t))
    schema = BaseTool.input_schema(t)
    assert schema["type"] == "object"
    assert "topic" in schema["required"]
  end

  test "run returns a finding for the given step (struct input)" do
    assert {:ok, %{"step" => 3, "finding" => finding}} =
             BaseTool.run(%ResearchStep{topic: "raft", n: 3})
    assert finding =~ "raft"
  end

  test "run tolerates a plain map with string keys" do
    assert {:ok, %{"step" => 2}} = BaseTool.run(%{"topic" => "paxos", "n" => 2})
  end
end
```

Note: the third test exercises the fallback clause for when the dispatch pipeline passes a raw input map rather than a built struct.

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test test/tools/research_step_test.exs`
Expected: FAIL (module not defined).

- [ ] **Step 3: Implement `tools/research_step.ex`**

```elixir
defmodule AutoresumeDemo.Tools.ResearchStep do
  @moduledoc "Lightweight tool an agent calls once per research step."
  defstruct [:topic, :n]

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "research_step"

    def tool_description(_),
      do:
        "Record one research step on the topic and return a short finding. " <>
          "Call once per step with the next step number n."

    def input_schema(_) do
      %{
        "type" => "object",
        "properties" => %{
          "topic" => %{"type" => "string", "description" => "The research topic"},
          "n" => %{"type" => "integer", "description" => "The step number (1-based)"}
        },
        "required" => ["topic", "n"]
      }
    end

    def run(%{topic: topic, n: n}) when not is_nil(topic) and not is_nil(n) do
      {:ok, %{"step" => n, "finding" => "Finding ##{n} about #{topic}."}}
    end

    def run(params) when is_map(params) do
      topic = Map.get(params, :topic) || Map.get(params, "topic") || "unknown"
      n = Map.get(params, :n) || Map.get(params, "n") || 0
      {:ok, %{"step" => n, "finding" => "Finding ##{n} about #{topic}."}}
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test test/tools/research_step_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/tools/research_step.ex examples/autoresume_demo/test/tools/research_step_test.exs
git commit -m "feat(demo): research_step tool"
```

---

### Task 5: `SimClient` (deterministic LLM stand-in for DEMO_MODE=simulated)

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/sim_client.ex`
- Test: `examples/autoresume_demo/test/sim_client_test.exs`

**Interfaces:**
- Produces: `%AutoresumeDemo.SimClient{topic, total_steps, step_delay_ms}` implementing `Normandy.Agents.Model`. `converse/7` returns `{%ToolCallResponse{...}, nil}`: a `research_step` tool call while fewer than `total_steps` assistant turns have occurred, otherwise an empty-tool-calls finalize. Built by `client_builder` (Task 6). Drives a multi-iteration tool loop without the network.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AutoresumeDemo.SimClientTest do
  use ExUnit.Case, async: true

  alias AutoresumeDemo.SimClient
  alias Normandy.Agents.Model
  alias Normandy.Agents.ToolCallResponse

  defp msg(role), do: %{role: role, content: "x"}

  test "emits a research_step tool call early in the conversation" do
    c = %SimClient{topic: "raft", total_steps: 3, step_delay_ms: 0}
    {resp, nil} = Model.converse(c, "m", 0.7, 1024, [msg("user")], %ToolCallResponse{}, [])
    assert [%{name: "research_step", input: %{"n" => 1}}] = resp.tool_calls
  end

  test "finalizes (no tool calls) once total_steps assistant turns have happened" do
    c = %SimClient{topic: "raft", total_steps: 2, step_delay_ms: 0}
    msgs = [msg("user"), msg("assistant"), msg("tool"), msg("assistant"), msg("tool")]
    {resp, nil} = Model.converse(c, "m", 0.7, 1024, msgs, %ToolCallResponse{}, [])
    assert resp.tool_calls == []
    assert resp.content =~ "raft"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test test/sim_client_test.exs`
Expected: FAIL (module not defined).

- [ ] **Step 3: Implement `sim_client.ex`**

```elixir
defmodule AutoresumeDemo.SimClient do
  @moduledoc """
  Deterministic LLM stand-in implementing Normandy.Agents.Model for
  DEMO_MODE=simulated. Drives a multi-step tool loop by counting prior assistant
  turns in the conversation: emits a research_step tool call until `total_steps`
  steps have run, then finalizes with plain content. A per-call sleep makes turns
  slow enough to kill a node mid-flight.
  """
  defstruct topic: "distributed systems", total_steps: 6, step_delay_ms: 1500

  defimpl Normandy.Agents.Model do
    alias Normandy.Agents.ToolCallResponse
    alias Normandy.Components.ToolCall

    def completitions(_c, _m, _t, _mt, _msgs, response_model), do: response_model

    def converse(client, _model, _temp, _max_tokens, messages, _response_model, _opts \\ []) do
      if client.step_delay_ms > 0, do: Process.sleep(client.step_delay_ms)

      done = count_assistant(messages)

      resp =
        if done < client.total_steps do
          step = done + 1

          %ToolCallResponse{
            content: "Researching #{client.topic} (step #{step}/#{client.total_steps})…",
            tool_calls: [
              %ToolCall{
                id: "sim-#{System.unique_integer([:positive])}",
                name: "research_step",
                input: %{"topic" => client.topic, "n" => step}
              }
            ]
          }
        else
          %ToolCallResponse{
            content:
              "Done researching #{client.topic}: synthesized #{client.total_steps} findings.",
            tool_calls: []
          }
        end

      {resp, nil}
    end

    defp count_assistant(messages),
      do: Enum.count(messages, fn m -> role_of(m) == "assistant" end)

    defp role_of(%{role: r}), do: to_string(r)
    defp role_of(%{"role" => r}), do: to_string(r)
    defp role_of(_), do: nil
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test test/sim_client_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/sim_client.ex examples/autoresume_demo/test/sim_client_test.exs
git commit -m "feat(demo): deterministic SimClient (Model protocol) for simulated mode"
```

---

### Task 6: `AutoresumeDemo.Agent` — config, client_builder switch, template & supplement

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/agent.ex`
- Test: `examples/autoresume_demo/test/agent_test.exs`

**Interfaces:**
- Consumes: `AutoresumeDemo.Tools.ResearchStep` (Task 4), `AutoresumeDemo.SimClient` (Task 5), `AutoresumeDemo.EnvCredentialProvider` (Task 3).
- Produces:
  - `AutoresumeDemo.Agent.template_id/0 :: "research"`
  - `AutoresumeDemo.Agent.total_steps/0 :: 6`
  - `AutoresumeDemo.Agent.tool_registry/0 :: Normandy.Tools.Registry.t()`
  - `AutoresumeDemo.Agent.client_builder/0 :: (String.t() -> struct())` — returns a `SimClient` in `:simulated` mode, a `ClaudioAdapter` otherwise (the ONLY real/sim seam).
  - `AutoresumeDemo.Agent.base_config/1 :: BaseAgentConfig.t()` (credential ref set in `behaviours`).
  - `AutoresumeDemo.Agent.build_template/0 :: map()` (eager template; `behaviours_refs.credential == {EnvCredentialProvider, []}`).
  - `AutoresumeDemo.Agent.supplement/0 :: AgentTemplate.supplement()` and `register_supplement/1` (puts it into a Catalog).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule AutoresumeDemo.AgentTest do
  use ExUnit.Case, async: false

  alias AutoresumeDemo.Agent
  alias AutoresumeDemo.SimClient
  alias Normandy.LLM.ClaudioAdapter

  test "client_builder returns a SimClient in simulated mode" do
    prev = Application.get_env(:autoresume_demo, :demo_mode)
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    on_exit(fn -> Application.put_env(:autoresume_demo, :demo_mode, prev) end)

    assert %SimClient{} = Agent.client_builder().("tok")
  end

  test "client_builder returns a ClaudioAdapter carrying the token in real mode" do
    prev = Application.get_env(:autoresume_demo, :demo_mode)
    Application.put_env(:autoresume_demo, :demo_mode, :real)
    on_exit(fn -> Application.put_env(:autoresume_demo, :demo_mode, prev) end)

    assert %ClaudioAdapter{api_key: "tok"} = Agent.client_builder().("tok")
  end

  test "the eager template carries the credential ref for Tier-2 reconstruction" do
    tmpl = Agent.build_template()
    assert tmpl.resume_policy == :eager
    assert tmpl.behaviours_refs.credential == {AutoresumeDemo.EnvCredentialProvider, []}
    assert tmpl.template_id == Agent.template_id()
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test test/agent_test.exs`
Expected: FAIL (module not defined).

- [ ] **Step 3: Implement `agent.ex`**

```elixir
defmodule AutoresumeDemo.Agent do
  @moduledoc """
  Builds the demo agent's config, the node-local Catalog supplement, and the
  persisted eager ConfigTemplate. The `client_builder/0` closure is the single
  real-vs-simulated switch — and the only seam carried through Tier-2
  reconstruction on a surviving node after a handoff.
  """
  alias Normandy.Agents.{BaseAgent, ConfigTemplate}
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Components.PromptSpecification
  alias Normandy.Tools.Registry
  alias AutoresumeDemo.SimClient
  alias AutoresumeDemo.Tools.ResearchStep

  @template_id "research"
  @topic "distributed systems"

  def template_id, do: @template_id
  def topic, do: @topic
  def total_steps, do: 6
  def model, do: Application.get_env(:autoresume_demo, :demo_model)

  def tool_registry, do: Registry.new([%ResearchStep{}])

  @doc "The single real/sim switch. Carried through Tier-2 reconstruction."
  def client_builder do
    mode = Application.get_env(:autoresume_demo, :demo_mode, :real)
    delay = Application.get_env(:autoresume_demo, :sim_step_delay_ms, 1500)
    topic = @topic
    steps = total_steps()

    fn token ->
      case mode do
        :simulated ->
          %SimClient{topic: topic, total_steps: steps, step_delay_ms: delay}

        _ ->
          %Normandy.LLM.ClaudioAdapter{api_key: token, options: %{timeout: 60_000}}
      end
    end
  end

  def base_config do
    BaseAgent.init(%{
      client: client_builder().(System.get_env("ANTHROPIC_API_KEY") || "SIMULATED-NO-KEY"),
      model: model(),
      temperature: 0.7,
      max_tokens: 1024,
      # total_steps tool calls + 1 finalizing call
      max_tool_iterations: total_steps() + 1,
      tool_registry: tool_registry(),
      name: "researcher",
      prompt_specification: %PromptSpecification{
        background: ["You research a topic step by step using the research_step tool."],
        steps: [
          "Call research_step once per step with the next step number n (1..#{total_steps()}).",
          "After #{total_steps()} steps, stop calling tools and write a 2-sentence synthesis."
        ],
        output_instructions: ["Be concise."]
      },
      # Credential ref travels in the template via from_config; client/tools/hooks
      # are resolved node-locally from the supplement.
      behaviours: %Normandy.Behaviours.Config{
        credential: {AutoresumeDemo.EnvCredentialProvider, []}
      }
    })
  end

  def build_template, do: ConfigTemplate.from_config(base_config(), @template_id, :eager)

  def supplement do
    %{
      tool_registry: tool_registry(),
      before_hooks: [],
      after_hooks: [],
      client_builder: client_builder()
    }
  end

  def register_supplement(catalog), do: Catalog.put(catalog, @template_id, supplement())
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test test/agent_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/agent.ex examples/autoresume_demo/test/agent_test.exs
git commit -m "feat(demo): agent config, client_builder switch, eager template + supplement"
```

---

### Task 7: Per-node OTP wiring (roles) + `Seeds` + single-node integration test

**Files:**
- Modify: `examples/autoresume_demo/lib/autoresume_demo/application.ex` (full version)
- Create: `examples/autoresume_demo/lib/autoresume_demo/topology.ex` (shared names/handles)
- Create: `examples/autoresume_demo/lib/autoresume_demo/seeds.ex`
- Test: `examples/autoresume_demo/test/single_node_integration_test.exs`

**Interfaces:**
- Consumes: `AutoresumeDemo.Agent` (Task 6), the Postgres store (Task 2).
- Produces:
  - `AutoresumeDemo.Topology` with: `registry/0`, `supervisor/0`, `catalog/0`, `store/0 :: {module, term}`, `registry_handle/0 :: {module, term}`, `template_provider/0 :: {module, term}`.
  - `AutoresumeDemo.Seeds.seed(topic, count) :: [session_id]` — starts `count` eager Tier-2 sessions through the Horde supervisor; persists each template; returns the session ids.
  - `AutoresumeDemo.Application` starting role-appropriate children. `DemoCollector`, `ClusterLauncher`, `Web.Router` are referenced here but implemented in Tasks 8–10; until then, the `:observer`/`:standalone` roles must tolerate their absence. To keep this task self-contained, role children for observer-only components are added in their own tasks; here we wire `:worker` and a minimal `:standalone`.

- [ ] **Step 1: Create `lib/autoresume_demo/topology.ex`**

```elixir
defmodule AutoresumeDemo.Topology do
  @moduledoc "Shared process names and behaviour handles used on every node."

  @registry AutoresumeDemo.SessionRegistry
  @supervisor AutoresumeDemo.TurnSupervisor
  @catalog AutoresumeDemo.AgentTemplates

  def registry, do: @registry
  def supervisor, do: @supervisor
  def catalog, do: @catalog

  def store, do: {Normandy.Behaviours.SessionStore.Postgres, AutoresumeDemo.Repo}
  def registry_handle, do: {Normandy.Behaviours.SessionRegistry.Horde, @registry}
  def template_provider, do: {Normandy.Behaviours.AgentTemplate.Catalog, @catalog}
end
```

- [ ] **Step 2: Replace `lib/autoresume_demo/application.ex` with the full role-based version**

```elixir
defmodule AutoresumeDemo.Application do
  @moduledoc false
  use Application
  require Logger

  alias AutoresumeDemo.Topology
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  @impl true
  def start(_type, _args) do
    role = Application.get_env(:autoresume_demo, :role, :standalone)
    Logger.info("autoresume_demo starting role=#{role} mode=#{Application.get_env(:autoresume_demo, :demo_mode)}")

    children = common_children() ++ role_children(role)
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: AutoresumeDemo.Supervisor)

    # Populate the node-local Catalog now that it is running.
    AutoresumeDemo.Agent.register_supplement(Topology.catalog())
    {:ok, sup}
  end

  # Registry member on EVERY node so the observer can do cluster-wide whereis.
  defp common_children do
    [
      AutoresumeDemo.Repo,
      %{id: Topology.catalog(), start: {Catalog, :start_link, [[name: Topology.catalog()]]}},
      %{id: Topology.registry(), start: {HReg, :start_link, [[name: Topology.registry()]]}}
    ]
  end

  defp role_children(:worker), do: worker_children()

  defp role_children(:observer) do
    # Observer-only components are added by their tasks (DemoCollector, Bandit,
    # ClusterLauncher). See Tasks 8-10. They are appended via observer_children/0.
    observer_children()
  end

  defp role_children(:standalone), do: worker_children() ++ standalone_extras()

  defp worker_children do
    [
      %{id: Topology.supervisor(), start: {HSup, :start_link, [[name: Topology.supervisor()]]}},
      %{
        id: ResumeReaper,
        start:
          {ResumeReaper, :start_link,
           [
             [
               store: Topology.store(),
               registry: Topology.registry_handle(),
               supervisor: Topology.supervisor(),
               supervisor_mod: HSup,
               template_provider: Topology.template_provider()
             ]
           ]}
      }
    ]
  end

  # Filled in by Tasks 9 & 10 (DemoCollector, Bandit, ClusterLauncher). Empty for now.
  defp observer_children, do: []
  # Filled in by Task 9 (DemoCollector) so a single-node dev VM also has the dashboard.
  defp standalone_extras, do: []
end
```

- [ ] **Step 3: Create `lib/autoresume_demo/seeds.ex`**

```elixir
defmodule AutoresumeDemo.Seeds do
  @moduledoc "Starts eager Tier-2 demo sessions through the Horde supervisor."
  require Logger

  alias AutoresumeDemo.{Agent, Topology}
  alias Normandy.Agents.Turn.Session

  @doc "Start `count` eager research sessions. Returns the list of session ids."
  @spec seed(String.t(), pos_integer()) :: [String.t()]
  def seed(topic \\ "distributed systems", count \\ 4) do
    {store_mod, store_handle} = Topology.store()
    tmpl = Agent.build_template()

    for i <- 1..count do
      sid = "research-#{:erlang.phash2({topic, i, System.unique_integer([:positive])})}"

      # Persist the eager template so the reaper can reconstruct on any node.
      :ok = store_mod.save_config_template(store_handle, sid, tmpl)

      opts = session_opts(sid)
      # Fire-and-forget: run kicks off the turn; we don't block on the result.
      spawn(fn ->
        case Session.run(opts, "Research #{topic} in #{Agent.total_steps()} steps.") do
          {:ok, _} -> :ok
          other -> Logger.warning("session #{sid} finished: #{inspect(other)}")
        end
      end)

      sid
    end
  end

  defp session_opts(sid) do
    [
      session_id: sid,
      config: Agent.base_config(),
      store: Topology.store(),
      registry: Topology.registry_handle(),
      supervisor: Topology.supervisor(),
      supervisor_mod: Normandy.Agents.Turn.Supervisor.Horde,
      template_provider: Topology.template_provider(),
      template_id: Agent.template_id(),
      resume_policy: :eager
    ]
  end
end
```

- [ ] **Step 4: Write the single-node integration test `test/single_node_integration_test.exs`**

This mirrors `tier2_integration_test.exs`: start the worker infra in one VM, seed a simulated session, assert it runs to completion (turn state becomes terminal).

```elixir
defmodule AutoresumeDemo.SingleNodeIntegrationTest do
  use ExUnit.Case, async: false

  alias AutoresumeDemo.{Agent, Seeds, Topology}
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup

  setup do
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    Application.put_env(:autoresume_demo, :sim_step_delay_ms, 0)

    start_supervised!(%{id: Topology.catalog(), start: {Catalog, :start_link, [[name: Topology.catalog()]]}})
    start_supervised!(%{id: Topology.registry(), start: {HReg, :start_link, [[name: Topology.registry()]]}})
    start_supervised!(%{id: Topology.supervisor(), start: {HSup, :start_link, [[name: Topology.supervisor()]]}})
    :ok = Agent.register_supplement(Topology.catalog())
    :ok
  end

  test "a simulated eager session runs the tool loop to a terminal state" do
    {store_mod, store_handle} = Topology.store()
    [sid] = Seeds.seed("raft", 1)

    assert eventually(fn ->
             case store_mod.load_turn_state(store_handle, sid) do
               {:ok, %Turn.State{status: status}} -> status in [:stopped, :failed]
               _ -> false
             end
           end, 60)
  end

  defp eventually(fun, tries) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: (Process.sleep(100); {:cont, false})
    end)
  end
end
```

- [ ] **Step 5: Run the integration test**

Run: `MIX_ENV=test mix test test/single_node_integration_test.exs`
Expected: PASS — the simulated session walks 6 tool steps and reaches `:stopped`. If it fails on tool-input casting (the dispatch pipeline building the `ResearchStep` struct from `%{"topic"=>…,"n"=>…}`), confirm `ResearchStep.run/1`'s map fallback clause handles it; the test will reveal the exact shape `run/1` receives.

- [ ] **Step 6: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/topology.ex examples/autoresume_demo/lib/autoresume_demo/application.ex examples/autoresume_demo/lib/autoresume_demo/seeds.ex examples/autoresume_demo/test/single_node_integration_test.exs
git commit -m "feat(demo): role-based OTP wiring + session seeds + single-node integration test"
```

---

### Task 8: `ClusterLauncher` + distributed handoff integration test

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/cluster_launcher.ex`
- Test: `examples/autoresume_demo/test/distributed_handoff_test.exs`

**Interfaces:**
- Consumes: `AutoresumeDemo.Topology`, `AutoresumeDemo.Seeds`, `AutoresumeDemo.Agent`.
- Produces (a GenServer registered as `AutoresumeDemo.ClusterLauncher`):
  - `AutoresumeDemo.ClusterLauncher.nodes/0 :: [{name :: atom, node :: node, peer_pid :: pid | :down}]`
  - `AutoresumeDemo.ClusterLauncher.kill(node) :: :ok` — stops the peer (triggers `:nodedown` → reaper handoff).
  - `AutoresumeDemo.ClusterLauncher.restart(node) :: :ok` — re-spawns a worker peer for that slot.
  - On init: spawns `worker_node_count` peers, sets app env + key on each, starts `:autoresume_demo` (role `:worker`) on each, then seeds sessions on the first worker.

- [ ] **Step 1: Implement `cluster_launcher.ex`**

```elixir
defmodule AutoresumeDemo.ClusterLauncher do
  @moduledoc """
  Observer-side GenServer that spawns worker :peer nodes, boots the demo app on
  each (role :worker), seeds sessions, and exposes kill/restart for the dashboard.
  """
  use GenServer
  require Logger

  alias AutoresumeDemo.Seeds

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def nodes, do: GenServer.call(__MODULE__, :nodes)
  def kill(node), do: GenServer.call(__MODULE__, {:kill, node})
  def restart(slot), do: GenServer.call(__MODULE__, {:restart, slot})

  @impl true
  def init(:ok) do
    # Ensure this (observer) node is distributed; iex --sname observer does this.
    count = Application.get_env(:autoresume_demo, :worker_node_count, 3)
    peers = for i <- 1..count, into: %{}, do: {slot(i), start_worker(slot(i))}
    # Seed on the first live worker so Horde distributes children across workers.
    {_slot, %{node: first}} = Enum.find(peers, fn {_s, %{node: n}} -> n != :down end) || {nil, %{node: :down}}
    if first != :down do
      :erpc.call(first, AutoresumeDemo.Seeds, :seed, [AutoresumeDemo.Agent.topic(), 5])
    end
    {:ok, %{peers: peers}}
  end

  @impl true
  def handle_call(:nodes, _from, state) do
    list = for {slot, info} <- state.peers, do: {slot, info.node, info.pid}
    {:reply, list, state}
  end

  def handle_call({:kill, node}, _from, state) do
    entry = Enum.find(state.peers, fn {_s, info} -> info.node == node end)

    case entry do
      {slot, %{pid: pid}} when is_pid(pid) ->
        Logger.warning("ClusterLauncher: killing #{node}")
        # Notify the collector first so the dashboard records the reason.
        AutoresumeDemo.DemoCollector.note_kill(node)
        :peer.stop(pid)
        peers = Map.put(state.peers, slot, %{node: node, pid: :down})
        {:reply, :ok, %{state | peers: peers}}

      _ ->
        {:reply, {:error, :unknown_node}, state}
    end
  end

  def handle_call({:restart, slot}, _from, state) when is_atom(slot) do
    info = start_worker(slot)
    {:reply, :ok, %{state | peers: Map.put(state.peers, slot, info)}}
  end

  defp slot(i), do: :"worker_#{i}"

  defp start_worker(slot) do
    cookie = Atom.to_charlist(:erlang.get_cookie())

    {:ok, pid, node} =
      :peer.start_link(%{
        name: slot,
        host: ~c"127.0.0.1",
        args: [~c"-setcookie", cookie]
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    # Copy the demo's runtime config + secret onto the peer BEFORE app start.
    for app <- [:autoresume_demo] do
      for {k, v} <- Application.get_all_env(app) do
        :ok = :erpc.call(node, Application, :put_env, [app, k, v])
      end
    end
    :ok = :erpc.call(node, Application, :put_env, [:autoresume_demo, :role, :worker])
    if key = System.get_env("ANTHROPIC_API_KEY"),
      do: :erpc.call(node, System, :put_env, ["ANTHROPIC_API_KEY", key])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:autoresume_demo])
    Logger.info("ClusterLauncher: worker up #{node}")
    %{node: node, pid: pid}
  end
end
```

Note: `DemoCollector.note_kill/1` is defined in Task 9; this task's test stubs it via a no-op if Task 9 isn't done yet, OR sequence Task 9 before exercising kill. Implement Task 9 before running the distributed test's kill assertions.

- [ ] **Step 2: Write the distributed handoff test `test/distributed_handoff_test.exs`**

Mirrors `eager_handoff_distributed_test.exs` + `resume_reaper_integration_test.exs`. Tagged `:distributed`; requires the test VM to be a named, distributed node.

```elixir
defmodule AutoresumeDemo.DistributedHandoffTest do
  use ExUnit.Case, async: false
  @moduletag :distributed
  @moduletag timeout: 120_000

  alias AutoresumeDemo.{Agent, Topology}
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  setup do
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    Application.put_env(:autoresume_demo, :sim_step_delay_ms, 800)
    Application.put_env(:autoresume_demo, :worker_node_count, 2)
    :ok
  end

  test "killing the worker hosting a session resumes it on the survivor" do
    # The observer VM runs a registry member so whereis is cluster-wide.
    {:ok, _} = ensure_started(%{id: Topology.catalog(),
      start: {Normandy.Behaviours.AgentTemplate.Catalog, :start_link, [[name: Topology.catalog()]]}})
    {:ok, _} = ensure_started(%{id: Topology.registry(),
      start: {HReg, :start_link, [[name: Topology.registry()]]}})
    {:ok, _} = ensure_started(AutoresumeDemo.Repo)
    :ok = Agent.register_supplement(Topology.catalog())

    {:ok, _} = AutoresumeDemo.ClusterLauncher.start_link(:ok)

    # Find a running session and the node it landed on.
    {store_mod, store_handle} = Topology.store()
    {sid, host_node} = await_running_session(store_mod, store_handle)

    # Kill that node.
    :ok = AutoresumeDemo.ClusterLauncher.kill(host_node)

    # Within seconds the reaper restarts the session on the OTHER worker.
    assert eventually(fn ->
             case HReg.whereis(Topology.registry(), sid) do
               {:ok, pid} -> node(pid) != host_node
               _ -> false
             end
           end, 120), "session #{sid} did not resume on a surviving node"

    # And it keeps making progress (iterations_left keeps decreasing or terminal).
    assert eventually(fn ->
             match?({:ok, %Turn.State{status: s}} when s in [:steering, :assistant_streaming, :tool_dispatch, :stopped],
                    store_mod.load_turn_state(store_handle, sid))
           end, 120)
  end

  defp await_running_session(store_mod, store_handle) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      with {:ok, sids} <- store_mod.list_resumable(store_handle),
           sid when not is_nil(sid) <-
             Enum.find(sids, fn s -> match?({:ok, _}, HReg.whereis(Topology.registry(), s)) end),
           {:ok, pid} <- HReg.whereis(Topology.registry(), sid) do
        {:halt, {sid, node(pid)}}
      else
        _ -> Process.sleep(100); {:cont, nil}
      end
    end)
  end

  defp ensure_started(spec) do
    case start_supervised(spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp eventually(fun, tries) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: (Process.sleep(200); {:cont, false})
    end)
  end
end
```

- [ ] **Step 3: Run the distributed test (named node + Postgres up + Task 9 done for note_kill)**

Run:
```bash
docker compose -f ../../docker-compose.verify.yml up -d postgres
MIX_ENV=test elixir --sname demotest --cookie demo -S mix test --only distributed test/distributed_handoff_test.exs
```
Expected: PASS — the session re-registers on a surviving node and continues. This is the core proof of the demo.

- [ ] **Step 4: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/cluster_launcher.ex examples/autoresume_demo/test/distributed_handoff_test.exs
git commit -m "feat(demo): cluster launcher (:peer) + distributed handoff integration test"
```

---

### Task 9: `DemoCollector` — authoritative per-agent view from store + registry + node monitor

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/demo_collector.ex`
- Test: `examples/autoresume_demo/test/demo_collector_test.exs`
- Modify: `examples/autoresume_demo/lib/autoresume_demo/application.ex` (`observer_children/0` and `standalone_extras/0` now include `DemoCollector`)

**Interfaces:**
- Consumes: `AutoresumeDemo.Topology` (store + registry), node monitoring.
- Produces (GenServer named `AutoresumeDemo.DemoCollector`):
  - `snapshot/0 :: %{nodes: [node_view], agents: [agent_view], events: [event], ts: integer}` where
    - `agent_view :: %{id, node, status, step, total, current_tool, resumed_from}` (`status` ∈ `"running" | "offline" | "done"`).
    - `node_view :: %{name, status}` (`"up" | "down"`).
    - `event :: %{ts, kind, text}`.
  - `note_kill(node) :: :ok` — record that `node` was killed manually (the "reason").
  - Internally polls every 500ms: `store.list_resumable` → per sid `load_turn_state` (status, iterations_left, pending_calls) + `registry.whereis` → node; folds into agent views; detects node changes after a down → `resumed_from`.

- [ ] **Step 1: Write the failing test** (drive the pure folding logic via injected fakes)

```elixir
defmodule AutoresumeDemo.DemoCollectorTest do
  use ExUnit.Case, async: true

  alias AutoresumeDemo.DemoCollector, as: C
  alias Normandy.Agents.Turn

  test "derives step/total/status from a turn state and a located node" do
    ts = %Turn.State{status: :steering, iterations_left: 2, max_iterations: 7}
    view = C.agent_view("s1", {:located, :"worker_2@h"}, {:ok, ts}, %{})
    assert view.id == "s1"
    assert view.node == :"worker_2@h"
    assert view.status == "running"
    assert view.step == 5
    assert view.total == 7
  end

  test "marks a session offline when not registered but still non-terminal" do
    ts = %Turn.State{status: :steering, iterations_left: 2, max_iterations: 7}
    view = C.agent_view("s1", :unlocated, {:ok, ts}, %{})
    assert view.status == "offline"
  end

  test "flags resumed_from when the node changed since last seen on a different node" do
    ts = %Turn.State{status: :steering, iterations_left: 1, max_iterations: 7}
    prev = %{"s1" => :"worker_1@h"}
    view = C.agent_view("s1", {:located, :"worker_3@h"}, {:ok, ts}, prev)
    assert view.resumed_from == :"worker_1@h"
  end

  test "terminal turn states are reported done" do
    ts = %Turn.State{status: :stopped, iterations_left: 0, max_iterations: 7}
    view = C.agent_view("s1", :unlocated, {:ok, ts}, %{})
    assert view.status == "done"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test test/demo_collector_test.exs`
Expected: FAIL (module/functions not defined).

- [ ] **Step 3: Implement `demo_collector.ex`**

```elixir
defmodule AutoresumeDemo.DemoCollector do
  @moduledoc """
  Observer-side authoritative view of the cluster. Polls the SAME durable state
  the resume mechanism uses (Postgres turn states) plus the Horde registry (which
  node each session is on) and monitors node up/down. Pure derivation lives in
  agent_view/4 so it is unit-testable.
  """
  use GenServer
  require Logger

  alias AutoresumeDemo.Topology
  alias Normandy.Agents.Turn

  @poll_ms 500
  @max_events 50

  # ---- public API ----
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def note_kill(node), do: GenServer.cast(__MODULE__, {:note_kill, node})

  # ---- pure derivation (unit tested) ----
  @doc false
  def agent_view(sid, located, turn_state_result, prev_nodes) do
    {status, step, total, tool} = derive(turn_state_result)

    {node, status} =
      case located do
        {:located, n} -> {n, if(status == "done", do: "done", else: "running")}
        :unlocated -> {nil, if(status == "done", do: "done", else: "offline")}
      end

    resumed_from =
      case {Map.get(prev_nodes, sid), node} do
        {prev, cur} when not is_nil(prev) and not is_nil(cur) and prev != cur -> prev
        _ -> nil
      end

    %{id: sid, node: node, status: status, step: step, total: total,
      current_tool: tool, resumed_from: resumed_from}
  end

  defp derive({:ok, %Turn.State{status: :stopped}}), do: {"done", nil, nil, nil}
  defp derive({:ok, %Turn.State{status: :failed}}), do: {"done", nil, nil, nil}

  defp derive({:ok, %Turn.State{} = ts}) do
    total = ts.max_iterations
    step = if total, do: total - (ts.iterations_left || 0), else: nil
    tool =
      case ts.pending_calls do
        [%{name: n} | _] -> n
        _ -> Atom.to_string(ts.status)
      end
    {"active", step, total, tool}
  end

  defp derive(_), do: {"unknown", nil, nil, nil}

  # ---- GenServer ----
  @impl true
  def init(:ok) do
    :net_kernel.monitor_nodes(true)
    state = %{agents: [], nodes: %{}, events: [], prev_nodes: %{}, killed: MapSet.new()}
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def handle_cast({:note_kill, node}, state) do
    {:noreply,
     %{state | killed: MapSet.put(state.killed, node)}
     |> add_event("kill", "#{node} killed (manual)")}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {store_mod, store_handle} = Topology.store()
    {reg_mod, reg_handle} = Topology.registry_handle()

    sids =
      case store_mod.list_resumable(store_handle) do
        {:ok, list} -> list
        _ -> []
      end

    agents =
      for sid <- sids do
        located =
          case reg_mod.whereis(reg_handle, sid) do
            {:ok, pid} -> {:located, node(pid)}
            _ -> :unlocated
          end

        agent_view(sid, located, store_mod.load_turn_state(store_handle, sid), state.prev_nodes)
      end

    prev_nodes =
      for %{id: id, node: n} <- agents, not is_nil(n), into: %{}, do: {id, n}

    events =
      agents
      |> Enum.filter(& &1.resumed_from)
      |> Enum.reduce(state.events, fn a, evs ->
        prepend_event(evs, "resume", "#{a.id} resumed on #{a.node} (was #{a.resumed_from})")
      end)

    {:noreply, %{state | agents: agents, prev_nodes: prev_nodes, events: events}}
  end

  def handle_info({:nodeup, node}, state),
    do: {:noreply, state |> put_node(node, "up") |> add_event("nodeup", "#{node} up")}

  def handle_info({:nodedown, node}, state),
    do: {:noreply, state |> put_node(node, "down") |> add_event("nodedown", "#{node} down")}

  defp put_node(state, node, status),
    do: %{state | nodes: Map.put(state.nodes, node, status)}

  defp add_event(state, kind, text),
    do: %{state | events: prepend_event(state.events, kind, text)}

  defp prepend_event(events, kind, text),
    do: Enum.take([%{ts: System.system_time(:millisecond), kind: kind, text: text} | events], @max_events)

  defp build_snapshot(state) do
    %{
      ts: System.system_time(:millisecond),
      nodes: for({name, status} <- state.nodes, do: %{name: to_string(name), status: status}),
      agents: state.agents,
      events: state.events
    }
  end
end
```

Note: `derive/1` returns `"active"` internally; `agent_view/4` maps it to `"running"`/`"offline"` based on whether the session is located. The unit tests assert the mapped values.

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test test/demo_collector_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire `DemoCollector` into observer/standalone roles**

In `application.ex`, change:

```elixir
  defp observer_children, do: []
```
to:
```elixir
  defp observer_children, do: [AutoresumeDemo.DemoCollector]
```
and:
```elixir
  defp standalone_extras, do: []
```
to:
```elixir
  defp standalone_extras, do: [AutoresumeDemo.DemoCollector]
```

- [ ] **Step 6: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/demo_collector.ex examples/autoresume_demo/test/demo_collector_test.exs examples/autoresume_demo/lib/autoresume_demo/application.ex
git commit -m "feat(demo): DemoCollector (store+registry poll, node monitor, resume detection)"
```

---

### Task 10: Web dashboard — Plug router, SSE, kill/restart, HTML page

**Files:**
- Create: `examples/autoresume_demo/lib/autoresume_demo/web/router.ex`
- Create: `examples/autoresume_demo/lib/autoresume_demo/web/page.ex`
- Test: `examples/autoresume_demo/test/web/router_test.exs`
- Modify: `examples/autoresume_demo/lib/autoresume_demo/application.ex` (`observer_children/0` adds the Bandit server + `ClusterLauncher`)

**Interfaces:**
- Consumes: `AutoresumeDemo.DemoCollector.snapshot/0`, `AutoresumeDemo.ClusterLauncher.kill/1` & `restart/1`.
- Produces: `AutoresumeDemo.Web.Router` (Plug) with routes `GET /` (HTML), `GET /events` (SSE stream of `snapshot/0` JSON every 500ms), `POST /kill/:node`, `POST /restart/:slot`. `AutoresumeDemo.Web.Page.html/0 :: String.t()`.

- [ ] **Step 1: Write the failing router test `test/web/router_test.exs`** (use `Plug.Test`)

```elixir
defmodule AutoresumeDemo.Web.RouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias AutoresumeDemo.Web.Router

  @opts Router.init([])

  setup do
    # DemoCollector must be running for / and /events.
    case AutoresumeDemo.DemoCollector.start_link(:ok) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
    :ok
  end

  test "GET / returns the dashboard HTML" do
    conn = conn(:get, "/") |> Router.call(@opts)
    assert conn.status == 200
    assert conn.resp_body =~ "Autoresume"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
  end

  test "POST /kill/:node returns 202 and does not crash with an unknown node" do
    conn = conn(:post, "/kill/nonexistent@127.0.0.1") |> Router.call(@opts)
    assert conn.status in [202, 404]
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test test/web/router_test.exs`
Expected: FAIL (module not defined).

- [ ] **Step 3: Implement `web/page.ex`** (self-contained HTML + JS; renders columns/cards/log from the SSE JSON)

```elixir
defmodule AutoresumeDemo.Web.Page do
  @moduledoc false

  def html do
    """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Normandy · Autoresume Live</title>
    <style>
      body{font:14px/1.4 ui-monospace,Menlo,Consolas,monospace;background:#0b0e14;color:#cdd6f4;margin:0;padding:16px}
      h1{font-size:16px;color:#89b4fa;margin:0 0 12px}
      #cols{display:flex;gap:12px;align-items:flex-start}
      .col{flex:1;border:1px solid #313244;border-radius:8px;padding:10px;min-height:160px}
      .col h2{font-size:13px;margin:0 0 8px;display:flex;justify-content:space-between}
      .up{color:#a6e3a1}.down{color:#f38ba8}
      .card{border:1px solid #45475a;border-radius:6px;padding:8px;margin:6px 0;background:#11151c}
      .bar{height:6px;background:#313244;border-radius:3px;overflow:hidden;margin:4px 0}
      .bar>i{display:block;height:100%;background:#89b4fa}
      .resumed{color:#f9e2af}
      button{font:inherit;background:#f38ba8;color:#11111b;border:0;border-radius:5px;padding:5px 8px;cursor:pointer;margin-top:6px}
      button.restart{background:#a6e3a1}
      #log{margin-top:14px;border-top:1px solid #313244;padding-top:8px;max-height:220px;overflow:auto}
      #log div{white-space:pre}
      .k-nodedown,.k-kill{color:#f38ba8}.k-resume,.k-nodeup{color:#a6e3a1}
    </style></head>
    <body>
      <h1>NORMANDY · Autoresume Live <span id="clock"></span></h1>
      <div id="cols"></div>
      <h1>EVENT LOG</h1>
      <div id="log"></div>
    <script>
      function post(p){fetch(p,{method:'POST'})}
      function render(s){
        document.getElementById('clock').textContent = new Date(s.ts).toLocaleTimeString();
        const byNode = {};
        (s.nodes||[]).forEach(n=>byNode[n.name]={status:n.status,agents:[]});
        (s.agents||[]).forEach(a=>{
          const key = a.node || 'unassigned';
          (byNode[key]=byNode[key]||{status:'up',agents:[]}).agents.push(a);
        });
        const cols = document.getElementById('cols'); cols.innerHTML='';
        Object.keys(byNode).sort().forEach(name=>{
          const n = byNode[name];
          const col = document.createElement('div'); col.className='col';
          const cls = n.status==='down'?'down':'up';
          let h = `<h2><span>${name}</span><span class="${cls}">${n.status==='down'?'✖ DOWN':'● UP'}</span></h2>`;
          (n.agents||[]).forEach(a=>{
            const pct = a.total? Math.round(100*(a.step||0)/a.total):0;
            h += `<div class="card"><b>${a.id}</b>`;
            if(a.resumed_from) h+=`<div class="resumed">↻ RESUMED from ${a.resumed_from}</div>`;
            h += `<div>${a.status} · step ${a.step||0}/${a.total||'?'} · ${a.current_tool||''}</div>`;
            h += `<div class="bar"><i style="width:${pct}%"></i></div></div>`;
          });
          if(name!=='unassigned'){
            h += `<button onclick="post('/kill/${name}')">Kill ${name}</button>`;
          }
          col.innerHTML=h; cols.appendChild(col);
        });
        const log = document.getElementById('log'); log.innerHTML='';
        (s.events||[]).forEach(e=>{
          const d=document.createElement('div'); d.className='k-'+e.kind;
          d.textContent = new Date(e.ts).toLocaleTimeString()+'  '+e.text; log.appendChild(d);
        });
      }
      const es = new EventSource('/events');
      es.onmessage = ev => { try{ render(JSON.parse(ev.data)); }catch(e){} };
    </script></body></html>
    """
  end
end
```

- [ ] **Step 4: Implement `web/router.ex`**

```elixir
defmodule AutoresumeDemo.Web.Router do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, AutoresumeDemo.Web.Page.html())
  end

  get "/events" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    stream_loop(conn)
  end

  post "/kill/:node" do
    target = String.to_atom(node)

    status =
      case AutoresumeDemo.ClusterLauncher.kill(target) do
        :ok -> 202
        _ -> 404
      end

    send_resp(conn, status, "")
  end

  post "/restart/:slot" do
    _ = AutoresumeDemo.ClusterLauncher.restart(String.to_atom(slot))
    send_resp(conn, 202, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp stream_loop(conn) do
    payload = AutoresumeDemo.DemoCollector.snapshot() |> Jason.encode!()

    case chunk(conn, "data: " <> payload <> "\n\n") do
      {:ok, conn} ->
        Process.sleep(500)
        stream_loop(conn)

      {:error, _} ->
        conn
    end
  end
end
```

- [ ] **Step 5: Run the router test**

Run: `MIX_ENV=test mix test test/web/router_test.exs`
Expected: PASS (2 tests). (The `/events` SSE loop is not asserted here — it streams forever; it is exercised manually in Task 11.)

- [ ] **Step 6: Wire Bandit + ClusterLauncher into the observer role**

In `application.ex`, replace:
```elixir
  defp observer_children, do: [AutoresumeDemo.DemoCollector]
```
with:
```elixir
  defp observer_children do
    port = Application.get_env(:autoresume_demo, :dashboard_port, 4000)
    [
      AutoresumeDemo.DemoCollector,
      {Bandit, plug: AutoresumeDemo.Web.Router, scheme: :http, port: port},
      AutoresumeDemo.ClusterLauncher
    ]
  end
```

- [ ] **Step 7: Commit**

```bash
git add examples/autoresume_demo/lib/autoresume_demo/web/page.ex examples/autoresume_demo/lib/autoresume_demo/web/router.ex examples/autoresume_demo/test/web/router_test.exs examples/autoresume_demo/lib/autoresume_demo/application.ex
git commit -m "feat(demo): web dashboard (Plug router, SSE, kill/restart) + page"
```

---

### Task 11: README, narration script, and end-to-end manual verification (both modes)

**Files:**
- Create: `examples/autoresume_demo/README.md`
- Modify: `examples/README.md` (add a third entry pointing at the demo)

**Interfaces:**
- Consumes: everything. Produces: documented, repeatable run instructions and a presenter's narration script.

- [ ] **Step 1: Write `examples/autoresume_demo/README.md`**

````markdown
# Autoresume Demo — Distributed Node-Kill Handoff

Real Claude-powered agents run on a local multi-node BEAM cluster. Kill a whole
node and watch the `ResumeReaper` reconstruct each agent on a surviving node and
resume it from persisted state — live, on a web dashboard.

## Prerequisites
- Docker (for Postgres) — or any Postgres reachable on `localhost:5432`.
- For real mode: `ANTHROPIC_API_KEY`.

## Run (real mode)
```bash
docker compose -f ../../docker-compose.verify.yml up -d postgres
export ANTHROPIC_API_KEY=sk-...
mix deps.get
mix ecto.setup
iex --sname observer --cookie demo -S mix
# open http://localhost:4000
```

## Run (simulated mode — no API key / offline, deterministic)
```bash
docker compose -f ../../docker-compose.verify.yml up -d postgres
export DEMO_MODE=simulated
mix deps.get && mix ecto.setup
iex --sname observer --cookie demo -S mix
# open http://localhost:4000
```

## What you'll see
- One column per worker node; each running agent is a card with a step counter
  and progress bar that keeps advancing (proof the agents are running).
- Click **Kill <node>**: the column flips to DOWN, the event log records the
  reason, and within seconds the agent reappears in another column with a
  **↻ RESUMED from <node>** badge and its step counter continuing.

## Configuration (env)
| Var | Default | Meaning |
|---|---|---|
| `DEMO_MODE` | `real` | `real` or `simulated` (no silent fallback) |
| `DEMO_MODEL` | `claude-3-5-sonnet-20241022` | model id (override to a newer id your account supports) |
| `WORKER_NODES` | `3` | number of worker :peer nodes |
| `DASHBOARD_PORT` | `4000` | web dashboard port |
| `SIM_STEP_DELAY_MS` | `1500` | per-step delay in simulated mode |
| `POSTGRES_*` | see config | DB connection |

## How it works
See `docs/superpowers/specs/2026-06-24-autoresume-demo-design.md`. The dashboard
reads the same durable Postgres state the resume mechanism uses; real-vs-simulated
switches only at the `client_builder` (the seam carried through Tier-2 handoff).
````

- [ ] **Step 2: Add an entry to `examples/README.md`**

Append under the examples list:

```markdown
### 3. Autoresume Demo (distributed node-kill handoff)

**Location**: `autoresume_demo/`

A live web dashboard demonstrating agents surviving a full BEAM node kill —
the ResumeReaper reconstructs and resumes them on a surviving node.

**[View Documentation](./autoresume_demo/README.md)**
```

- [ ] **Step 3: Manual end-to-end verification — SIMULATED mode**

Run:
```bash
docker compose -f ../../docker-compose.verify.yml up -d postgres
cd examples/autoresume_demo && export DEMO_MODE=simulated && mix deps.get && mix ecto.reset
iex --sname observer --cookie demo -S mix
```
Then open `http://localhost:4000`. Verify against spec acceptance criteria:
- Columns appear for ~3 workers with agent cards whose step counters advance.
- Click **Kill worker_2@127.0.0.1**: column → DOWN, log shows `nodedown` + `kill`.
- Within seconds an agent that was on worker_2 reappears under another worker with **RESUMED from worker_2** and continues counting.
Record PASS/FAIL for each.

- [ ] **Step 4: Manual end-to-end verification — REAL mode**

Run the same with `export DEMO_MODE=real` and a valid `ANTHROPIC_API_KEY` (and `ecto.reset`). Confirm agents make real calls (slower, real content), and the same kill→resume flow holds. Record PASS/FAIL.

- [ ] **Step 5: Run the full demo test suite once more**

Run:
```bash
MIX_ENV=test mix test
MIX_ENV=test elixir --sname demotest --cookie demo -S mix test --only distributed
```
Expected: all unit + integration tests PASS; the distributed handoff test PASSES.

- [ ] **Step 6: Commit**

```bash
git add examples/autoresume_demo/README.md examples/README.md
git commit -m "docs(demo): autoresume demo README + examples index entry"
```

---

## Self-Review

**1. Spec coverage** (spec sections → tasks):
- §2 Decisions (Postgres+Horde, web SSE, real+sim, peer+kill button) → Tasks 2, 7, 8, 10; real/sim → Tasks 5, 6.
- §3 Grounded mechanism → encoded in the "Verified API surface" block + Tasks 6–9.
- §4.1 Topology → Tasks 7 (roles), 8 (peers).
- §4.2 Agents/work → Tasks 4 (tool), 6 (config, 6 steps).
- §4.3 Failure→resume flow → Task 8 (launcher kill + reaper) verified by the distributed test.
- §4.4 Dashboard mockup → Task 10 (page + columns/cards/log/kill button).
- §5 Event flow (survives handoff) → Task 9 (pull-based: store+registry poll + node monitor). **Deviation from spec's push-based §5/§6 — see note below.**
- §7 Project layout → Tasks 1–10 create the listed files (single `research_step` tool instead of also `summarize` — YAGNI, see note).
- §8 DEMO_MODE no silent fallback → Tasks 1 (config), 3 (credential), 6 (client_builder).
- §10 Acceptance criteria 1–7 → criteria 1–6 verified in Task 11 manual steps + Task 8 test; criterion 7 verified in Task 1 Step 7.
- §11 Out of scope → respected (no auth, single store, one flow).

**2. Placeholder scan:** No "TBD"/"handle errors appropriately"/"similar to Task N". Each code step shows complete code. Two honest verification notes are flagged (tool-input casting in Task 7 Step 5; `note_kill` ordering between Tasks 8/9) — these are real run-and-observe checks, not placeholders.

**3. Type consistency:** `Topology.store/0` = `{Postgres, Repo}` used consistently in Seeds/Collector/Reaper. `client_builder/0` returns `(token -> struct)` used in Agent.supplement + base_config. `agent_view/4` signature matches its test and its caller in `handle_info(:poll)`. `snapshot/0` shape (nodes/agents/events/ts) matches the page JS field names (`node`,`status`,`step`,`total`,`current_tool`,`resumed_from`,`name`,`kind`,`text`). `Session.run/2` opts match the verified eager-session keys. ResumeReaper opts match the verified signature.

### Deviations from the spec (intentional, recorded)
1. **Pull-based collector instead of push-based tool heartbeat (spec §5/§6).** During planning it became clear a tool's `run/1` cannot know its `session_id` without fragile prompt coupling, and the reaper's thin restart carries no subscriber/handlers. Polling the Postgres store + Horde registry is authoritative, knows the session id natively, survives handoff for free, and reads the *same durable state the resume relies on* — strictly more robust. Spec §5/§6 should be updated to match.
2. **One tool (`research_step`) instead of `research_step` + `summarize` (spec §7).** The final synthesis is the agent's tool-less closing message; a second tool adds nothing the acceptance criteria need. YAGNI.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-24-autoresume-demo.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
