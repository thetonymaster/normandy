# Phase 2 — Pluggable Behaviours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `%Dispatch.Pipeline{}` function slots into four real Elixir `@behaviour`s (`PolicyEngine`, `BudgetTracker`, `CredentialProvider`, `ModelCatalog`) with default impls that preserve current behavior, selectable per-agent via a `behaviours` bundle on `BaseAgentConfig`, with `before/after` hooks as first-class config-selectable fn slots.

**Architecture:** Each behaviour is a module defining `@callback`s plus a default impl submodule. A `Normandy.Behaviours.Config` bundle struct carries one `{module, opts}` ref per behaviour; `Config.to_pipeline/1` adapts the dispatch-path slots (policy/budget/hooks) into the existing `%Dispatch.Pipeline{}` — so `dispatch_one/3` and `dispatch.ex` are untouched. `CredentialProvider`/`ModelCatalog` are off the dispatch path: `ModelCatalog.Static` becomes the single source for `WindowManager`'s limits; `CredentialProvider` is defined + defaulted but its LLM-call consumption is deferred. With the default bundle, observable output is byte-identical to today (the existing suite is the parity oracle).

**Tech Stack:** Elixir, ExUnit, `:telemetry`. New namespace `Normandy.Behaviours.*`. Existing modules touched: `Normandy.Agents.BaseAgentConfig`, `Normandy.Agents.BaseAgent`, `Normandy.Context.WindowManager`, `mix.exs`, `CHANGELOG.md`.

**Spec:** `docs/superpowers/specs/2026-06-01-phase-2-pluggable-behaviours-design.md`

**Project rules (`CLAUDE.md`):** run `mix format` before tests; if tests fail, fix them; add files individually to git (no `git add .`); no AI attribution in commits. Run one test with `mix test path:LINE`.

---

## File Structure

- **Create:** `lib/normandy/behaviours/policy_engine.ex` — `Normandy.Behaviours.PolicyEngine` behaviour + `.AllowAll` (default) + `.Ruleset` (shipped non-default).
- **Create:** `lib/normandy/behaviours/budget_tracker.ex` — `Normandy.Behaviours.BudgetTracker` behaviour + `.NoOp` (default).
- **Create:** `lib/normandy/behaviours/credential_provider.ex` — `Normandy.Behaviours.CredentialProvider` behaviour + `.FromClient` (default).
- **Create:** `lib/normandy/behaviours/model_catalog.ex` — `Normandy.Behaviours.ModelCatalog` behaviour + `.Static` (default; canonical limits).
- **Create:** `lib/normandy/behaviours/config.ex` — `Normandy.Behaviours.Config` bundle struct + `to_pipeline/1`.
- **Create:** `test/behaviours/policy_engine_test.exs`, `budget_tracker_test.exs`, `credential_provider_test.exs`, `model_catalog_test.exs`, `config_test.exs`.
- **Modify:** `lib/normandy/context/window_manager.ex` — source limits from `ModelCatalog.Static`.
- **Modify:** `lib/normandy/agents/base_agent_config.ex` — add `behaviours` field.
- **Modify:** `lib/normandy/agents/base_agent.ex` — `init/1` sets `behaviours`; `base_agent_pipeline/1` builds from it.
- **Modify:** `mix.exs`, `CHANGELOG.md` — `0.6.3 → 0.7.0`.

---

## Task 1: PolicyEngine behaviour + AllowAll default

**Files:**
- Create: `lib/normandy/behaviours/policy_engine.ex`
- Test: `test/behaviours/policy_engine_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/behaviours/policy_engine_test.exs
defmodule Normandy.Behaviours.PolicyEngineTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.PolicyEngine
  alias Normandy.Components.ToolCall

  describe "AllowAll" do
    test "allows every call regardless of call or ctx" do
      assert PolicyEngine.AllowAll.check(%ToolCall{name: "anything"}, %{}) == {:allow, %{}}
      assert PolicyEngine.AllowAll.check(%{}, %{config: %{}, tool: %{}, opts: []}) == {:allow, %{}}
    end

    test "implements the PolicyEngine behaviour" do
      behaviours = PolicyEngine.AllowAll.module_info(:attributes)[:behaviour] || []
      assert PolicyEngine in behaviours
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/policy_engine_test.exs`
Expected: FAIL — `module Normandy.Behaviours.PolicyEngine is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/normandy/behaviours/policy_engine.ex
defmodule Normandy.Behaviours.PolicyEngine do
  @moduledoc """
  Contract for per-tool-call policy decisions, consulted at the dispatch
  chokepoint via `Normandy.Behaviours.Config.to_pipeline/1`.

  `check/2` returns one of:

    * `{:allow, meta}` — proceed; `meta` is opaque allow-context.
    * `{:deny, info}` — block; `info` may carry `:reason`, `:rule_id`,
      `:rationale`. The rationale is fed back into the model context by the
      chokepoint, so the model learns *why* a constraint exists.
    * `{:needs_approval, info}` — park for human approval (interim-tagged in
      Phase 1; real parking lands in Phase 4).

  The default impl `AllowAll` preserves current (allow-everything) behavior.
  """

  @type call :: term()
  @type ctx :: map()
  @type decision :: {:allow, map()} | {:deny, map()} | {:needs_approval, map()}

  @callback check(call(), ctx()) :: decision()

  defmodule AllowAll do
    @moduledoc "Default PolicyEngine: allows every call (back-compat)."
    @behaviour Normandy.Behaviours.PolicyEngine

    @impl true
    def check(_call, _ctx), do: {:allow, %{}}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/policy_engine_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/policy_engine.ex test/behaviours/policy_engine_test.exs
git commit -m "feat(behaviours): add PolicyEngine behaviour and AllowAll default"
```

---

## Task 2: PolicyEngine.Ruleset (shipped non-default impl)

**Files:**
- Modify: `lib/normandy/behaviours/policy_engine.ex`
- Test: `test/behaviours/policy_engine_test.exs`

- [ ] **Step 1: Write the failing tests**

Append inside `Normandy.Behaviours.PolicyEngineTest` (after the `AllowAll` describe):

```elixir
  describe "Ruleset" do
    defp ctx(rules, default_action) do
      %{opts: [rules: rules, default_action: default_action]}
    end

    test "first matching rule wins (exact name)" do
      rules = [
        %{match: "billing_charge", action: :deny, rule_id: "R-1", rationale: "needs approval"},
        %{match: "*", action: :allow}
      ]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "billing_charge"}, ctx(rules, :allow)) ==
               {:deny, %{reason: "needs approval", rule_id: "R-1", rationale: "needs approval"}}

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :allow)) ==
               {:allow, %{}}
    end

    test "glob prefix match" do
      rules = [%{match: "billing_*", action: :deny, rule_id: "R-2", rationale: "billing blocked"}]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "billing_refund"}, ctx(rules, :allow)) ==
               {:deny, %{reason: "billing blocked", rule_id: "R-2", rationale: "billing blocked"}}

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :allow)) ==
               {:allow, %{}}
    end

    test ":require_approval maps to {:needs_approval, info}" do
      rules = [%{match: "deploy", action: :require_approval, rule_id: "R-3", rationale: "prod gate"}]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "deploy"}, ctx(rules, :allow)) ==
               {:needs_approval, %{reason: "prod gate", rule_id: "R-3", rationale: "prod gate"}}
    end

    test "falls back to default_action when nothing matches" do
      rules = [%{match: "billing_*", action: :deny}]

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :deny)) ==
               {:deny, %{reason: nil, rule_id: nil, rationale: nil}}

      assert PolicyEngine.Ruleset.check(%ToolCall{name: "weather"}, ctx(rules, :allow)) ==
               {:allow, %{}}
    end

    test "implements the PolicyEngine behaviour" do
      behaviours = PolicyEngine.Ruleset.module_info(:attributes)[:behaviour] || []
      assert PolicyEngine in behaviours
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/policy_engine_test.exs`
Expected: FAIL — `Normandy.Behaviours.PolicyEngine.Ruleset.check/2 is undefined`.

- [ ] **Step 3: Write the implementation**

Add the `Ruleset` submodule inside `Normandy.Behaviours.PolicyEngine` (after `AllowAll`, before the closing `end`):

```elixir
  defmodule Ruleset do
    @moduledoc """
    PolicyEngine that evaluates an ordered list of in-memory rules, first match
    wins, with a configurable default action. The ruleset is supplied through
    the behaviour opts on `ctx.opts`:

      * `:rules` — list of `%{match, action, rule_id, rationale}` maps. `match`
        is a tool-name glob (`"*"` / `"prefix_*"` / exact). `action` is
        `:allow | :deny | :require_approval`.
      * `:default_action` — action when no rule matches (default `:allow`).

    A YAML-file loader is intentionally deferred — YAML is only a serialization
    of this in-memory shape.
    """
    @behaviour Normandy.Behaviours.PolicyEngine

    @impl true
    def check(call, ctx) do
      opts = Map.get(ctx, :opts, [])
      rules = Keyword.get(opts, :rules, [])
      default_action = Keyword.get(opts, :default_action, :allow)
      name = call_name(call)

      case Enum.find(rules, fn rule -> matches?(rule[:match], name) end) do
        nil -> decide(default_action, empty_meta())
        rule -> decide(rule[:action] || :allow, rule_meta(rule))
      end
    end

    defp call_name(%{name: name}) when is_binary(name), do: name
    defp call_name(_), do: ""

    defp empty_meta, do: %{reason: nil, rule_id: nil, rationale: nil}

    defp rule_meta(rule) do
      %{
        reason: rule[:reason] || rule[:rationale],
        rule_id: rule[:rule_id],
        rationale: rule[:rationale]
      }
    end

    defp decide(:allow, _meta), do: {:allow, %{}}
    defp decide(:deny, meta), do: {:deny, meta}
    defp decide(:require_approval, meta), do: {:needs_approval, meta}

    defp matches?("*", _name), do: true
    defp matches?(nil, _name), do: false

    defp matches?(pattern, name) when is_binary(pattern) do
      if String.ends_with?(pattern, "*") do
        String.starts_with?(name, String.trim_trailing(pattern, "*"))
      else
        pattern == name
      end
    end

    defp matches?(_pattern, _name), do: false
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/policy_engine_test.exs`
Expected: PASS (all PolicyEngine tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/policy_engine.ex test/behaviours/policy_engine_test.exs
git commit -m "feat(behaviours): add PolicyEngine.Ruleset in-memory rule evaluator"
```

---

## Task 3: BudgetTracker behaviour + NoOp default

**Files:**
- Create: `lib/normandy/behaviours/budget_tracker.ex`
- Test: `test/behaviours/budget_tracker_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/behaviours/budget_tracker_test.exs
defmodule Normandy.Behaviours.BudgetTrackerTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.BudgetTracker

  describe "NoOp" do
    test "check/2 always returns :ok" do
      assert BudgetTracker.NoOp.check(%{agent: "a"}, %{any: :thing}) == :ok
    end

    test "record/2 always returns :ok" do
      assert BudgetTracker.NoOp.record(%{agent: "a"}, %{tokens: 100}) == :ok
    end

    test "implements the BudgetTracker behaviour" do
      behaviours = BudgetTracker.NoOp.module_info(:attributes)[:behaviour] || []
      assert BudgetTracker in behaviours
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/budget_tracker_test.exs`
Expected: FAIL — `module Normandy.Behaviours.BudgetTracker is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/normandy/behaviours/budget_tracker.ex
defmodule Normandy.Behaviours.BudgetTracker do
  @moduledoc """
  Contract for budget gating and accounting around tool calls.

  `check/2` is an optional pre-spend gate (returns `:ok` to proceed or
  `{:error, reason}` to deny before executing); `record/2` accounts for actual
  usage after the call. `scope` identifies the budget owner (e.g.
  `%{agent: name, model: model}`); `est`/`usage` are the planned/actual cost
  carriers. The default impl `NoOp` preserves current (untracked) behavior.
  """

  @type scope :: term()

  @callback check(scope(), est :: term()) :: :ok | {:error, term()}
  @callback record(scope(), usage :: term()) :: :ok

  defmodule NoOp do
    @moduledoc "Default BudgetTracker: no gating, no accounting (back-compat)."
    @behaviour Normandy.Behaviours.BudgetTracker

    @impl true
    def check(_scope, _est), do: :ok

    @impl true
    def record(_scope, _usage), do: :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/budget_tracker_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/budget_tracker.ex test/behaviours/budget_tracker_test.exs
git commit -m "feat(behaviours): add BudgetTracker behaviour and NoOp default"
```

---

## Task 4: CredentialProvider behaviour + FromClient default

**Files:**
- Create: `lib/normandy/behaviours/credential_provider.ex`
- Test: `test/behaviours/credential_provider_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/behaviours/credential_provider_test.exs
defmodule Normandy.Behaviours.CredentialProviderTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.CredentialProvider
  alias Normandy.LLM.ClaudioAdapter

  describe "FromClient" do
    test "extracts a binary api_key from a client struct" do
      client = %ClaudioAdapter{api_key: "sk-test-123"}
      assert CredentialProvider.FromClient.get_token(client, []) == {:ok, "sk-test-123"}
    end

    test "extracts api_key from any map exposing the field (no hard ClaudioAdapter dep)" do
      assert CredentialProvider.FromClient.get_token(%{api_key: "sk-abc"}, []) == {:ok, "sk-abc"}
    end

    test "returns {:error, :no_api_key} when absent or non-binary" do
      assert CredentialProvider.FromClient.get_token(%{}, []) == {:error, :no_api_key}
      assert CredentialProvider.FromClient.get_token(%{api_key: nil}, []) == {:error, :no_api_key}
    end

    test "implements the CredentialProvider behaviour" do
      behaviours = CredentialProvider.FromClient.module_info(:attributes)[:behaviour] || []
      assert CredentialProvider in behaviours
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/credential_provider_test.exs`
Expected: FAIL — `module Normandy.Behaviours.CredentialProvider is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/normandy/behaviours/credential_provider.ex
defmodule Normandy.Behaviours.CredentialProvider do
  @moduledoc """
  Contract for resolving an LLM provider token.

  Defined and defaulted in Phase 2; its consumption at the `Model.converse`
  boundary is deferred (the token still flows through `config.client` today).
  The default impl `FromClient` extracts the `api_key` already carried on the
  client struct, matching any client that exposes a binary `:api_key` so it
  stays decoupled from `Normandy.LLM`.
  """

  @callback get_token(provider :: term(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  defmodule FromClient do
    @moduledoc "Default CredentialProvider: reads the binary api_key off the client."
    @behaviour Normandy.Behaviours.CredentialProvider

    @impl true
    def get_token(%{api_key: key}, _opts) when is_binary(key), do: {:ok, key}
    def get_token(_provider, _opts), do: {:error, :no_api_key}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/credential_provider_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/credential_provider.ex test/behaviours/credential_provider_test.exs
git commit -m "feat(behaviours): add CredentialProvider behaviour and FromClient default"
```

---

## Task 5: ModelCatalog behaviour + Static default (canonical limits)

**Files:**
- Create: `lib/normandy/behaviours/model_catalog.ex`
- Test: `test/behaviours/model_catalog_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/behaviours/model_catalog_test.exs
defmodule Normandy.Behaviours.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.ModelCatalog

  describe "Static" do
    test "context_window/1 returns the known limit, nil for unknown" do
      assert ModelCatalog.Static.context_window("claude-haiku-4-5-20251001") == 200_000
      assert ModelCatalog.Static.context_window("claude-3-opus-20240229") == 200_000
      assert ModelCatalog.Static.context_window("unknown-model") == nil
    end

    test "get/1 returns context_window + capabilities for known models, :error otherwise" do
      assert {:ok, %{context_window: 200_000, capabilities: caps}} =
               ModelCatalog.Static.get("claude-3-5-sonnet-20241022")

      assert :tools in caps
      assert ModelCatalog.Static.get("unknown-model") == :error
    end

    test "supports?/2 checks capability membership" do
      assert ModelCatalog.Static.supports?("claude-3-haiku-20240307", :vision)
      refute ModelCatalog.Static.supports?("claude-3-haiku-20240307", :code_execution)
      refute ModelCatalog.Static.supports?("unknown-model", :tools)
    end

    test "limits/0 exposes the canonical map (single source of truth)" do
      limits = ModelCatalog.Static.limits()
      assert is_map(limits)
      assert limits["claude-haiku-4-5-20251001"] == 200_000
    end

    test "implements the ModelCatalog behaviour" do
      behaviours = ModelCatalog.Static.module_info(:attributes)[:behaviour] || []
      assert ModelCatalog in behaviours
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/model_catalog_test.exs`
Expected: FAIL — `module Normandy.Behaviours.ModelCatalog is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/normandy/behaviours/model_catalog.ex
defmodule Normandy.Behaviours.ModelCatalog do
  @moduledoc """
  Contract for model capability/limit lookup.

  The default impl `Static` is the canonical home for the context-window limits
  that previously lived hardcoded on `Normandy.Context.WindowManager`. Phase 2
  consumption is limited to `WindowManager` sourcing its limits here; turn-loop
  consumption (compaction) arrives in Phase 5.
  """

  @callback get(model :: String.t()) :: {:ok, map()} | :error
  @callback supports?(model :: String.t(), capability :: atom()) :: boolean()
  @callback context_window(model :: String.t()) :: pos_integer() | nil

  defmodule Static do
    @moduledoc """
    Default ModelCatalog: a fixed catalog absorbing `WindowManager`'s hardcoded
    context-window limits. All listed models are tool/vision/streaming-capable.
    """
    @behaviour Normandy.Behaviours.ModelCatalog

    @capabilities [:tools, :vision, :streaming]

    @limits %{
      "claude-haiku-4-5-20251001" => 200_000,
      "claude-3-5-sonnet-20241022" => 200_000,
      "claude-3-5-haiku-20241022" => 200_000,
      "claude-3-opus-20240229" => 200_000,
      "claude-3-sonnet-20240229" => 200_000,
      "claude-3-haiku-20240307" => 200_000
    }

    @doc "The canonical context-window limits map (single source of truth)."
    @spec limits() :: %{String.t() => pos_integer()}
    def limits, do: @limits

    @impl true
    def get(model) do
      case Map.fetch(@limits, model) do
        {:ok, window} -> {:ok, %{context_window: window, capabilities: @capabilities}}
        :error -> :error
      end
    end

    @impl true
    def supports?(model, capability) do
      case get(model) do
        {:ok, %{capabilities: caps}} -> capability in caps
        :error -> false
      end
    end

    @impl true
    def context_window(model) do
      case Map.fetch(@limits, model) do
        {:ok, window} -> window
        :error -> nil
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/model_catalog_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/model_catalog.ex test/behaviours/model_catalog_test.exs
git commit -m "feat(behaviours): add ModelCatalog behaviour and Static catalog"
```

---

## Task 6: WindowManager sources limits from ModelCatalog.Static

**Files:**
- Modify: `lib/normandy/context/window_manager.ex` (`defstruct` model_limits default at `:43-53`; `for_model/2` at `:91-96`)
- Test: `test/context/window_manager_test.exs` (parity oracle — must stay green) + one new agreement test.

The existing `for_model/2` tests are the parity oracle: `for_model("claude-haiku-4-5-20251001")` → `200_000`, unknown → `100_000`. This task must keep them green while removing the duplicated literal map.

- [ ] **Step 1: Add a regression test that catalog and WindowManager agree**

Append to `test/context/window_manager_test.exs` inside the `describe "for_model/2"` block (before its closing `end`):

```elixir
    test "sources limits from the canonical ModelCatalog (single source of truth)" do
      for {model, window} <- Normandy.Behaviours.ModelCatalog.Static.limits() do
        assert WindowManager.for_model(model).max_tokens == window
      end
    end
```

- [ ] **Step 2: Run it to verify it passes against the current literal map**

Run: `mix test test/context/window_manager_test.exs`
Expected: PASS — the current hardcoded `model_limits` already equals the catalog's `@limits` (identical entries), so the agreement test passes *before* the refactor. This proves the catalog is a faithful copy before we make it the source.

- [ ] **Step 3: Replace the duplicated literal with the catalog as source**

In `lib/normandy/context/window_manager.ex`, change the `defstruct` (currently `:43-53`) from:

```elixir
  defstruct max_tokens: 100_000,
            reserved_tokens: 4096,
            strategy: :oldest_first,
            model_limits: %{
              "claude-haiku-4-5-20251001" => 200_000,
              "claude-3-5-sonnet-20241022" => 200_000,
              "claude-3-5-haiku-20241022" => 200_000,
              "claude-3-opus-20240229" => 200_000,
              "claude-3-sonnet-20240229" => 200_000,
              "claude-3-haiku-20240307" => 200_000
            }
```

to (single source; struct shape unchanged — `model_limits` field still present):

```elixir
  defstruct max_tokens: 100_000,
            reserved_tokens: 4096,
            strategy: :oldest_first,
            model_limits: Normandy.Behaviours.ModelCatalog.Static.limits()
```

Then change `for_model/2` (currently `:91-96`) from:

```elixir
  def for_model(model, opts \\ []) do
    manager = new(opts)
    model_limit = Map.get(manager.model_limits, model, manager.max_tokens)

    %{manager | max_tokens: model_limit}
  end
```

to consult the catalog directly:

```elixir
  def for_model(model, opts \\ []) do
    manager = new(opts)
    model_limit = Normandy.Behaviours.ModelCatalog.Static.context_window(model) || manager.max_tokens

    %{manager | max_tokens: model_limit}
  end
```

- [ ] **Step 4: Run the WindowManager suite (parity oracle) + the new test**

Run: `mix format && mix test test/context/window_manager_test.exs`
Expected: PASS — all existing `for_model/2` tests green (200_000 / 100_000 fallback unchanged) plus the agreement test.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/context/window_manager.ex test/context/window_manager_test.exs
git commit -m "refactor(window_manager): source context-window limits from ModelCatalog.Static"
```

---

## Task 7: Behaviours.Config bundle + to_pipeline/1

**Files:**
- Create: `lib/normandy/behaviours/config.ex`
- Test: `test/behaviours/config_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/behaviours/config_test.exs
defmodule Normandy.Behaviours.ConfigTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.PolicyEngine
  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Dispatch.Pipeline
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Registry

  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Behaviours.ConfigTest.FakeTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

  defp config_with_tools(tools) do
    %{name: "test-agent", model: "claude-3-5-sonnet-20241022", tool_registry: Registry.new(tools)}
  end

  describe "default bundle" do
    test "has all-default impl refs" do
      b = %Config{}
      assert b.policy == {PolicyEngine.AllowAll, []}
      assert b.budget == {Normandy.Behaviours.BudgetTracker.NoOp, []}
      assert b.before_hooks == []
      assert b.after_hooks == []
      assert b.credential == {Normandy.Behaviours.CredentialProvider.FromClient, []}
      assert b.model_catalog == {Normandy.Behaviours.ModelCatalog.Static, []}
    end
  end

  describe "to_pipeline/1 equivalence with default_pipeline/0" do
    test "default bundle reproduces the chokepoint's default behaviour" do
      p = Config.to_pipeline(%Config{})
      d = Dispatch.default_pipeline()

      assert %Pipeline{} = p
      assert p.before_hooks == d.before_hooks
      assert p.after_hooks == d.after_hooks
      assert p.policy_fn.(%{}, %ToolCall{name: "x"}, %{}) == {:allow, %{}}
      assert p.budget_check_fn.(%{}, %ToolCall{name: "x"}) == :ok
      assert p.budget_record_fn.(%{}, %ToolCall{name: "x"}, %{}) == :ok
    end

    test "nil resolves to the default bundle" do
      assert Config.to_pipeline(nil) == Config.to_pipeline(%Config{})
    end

    test "default bundle executes a tool through dispatch_one/3" do
      pipeline = Config.to_pipeline(%Config{})
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      assert %ToolResult{tool_call_id: "c1", output: "weather in NYC", is_error: false} =
               Dispatch.dispatch_one(config, call, pipeline)
    end
  end

  describe "to_pipeline/1 with a non-default bundle" do
    test "a Ruleset policy denies a matching tool through dispatch_one/3" do
      bundle = %Config{
        policy:
          {PolicyEngine.Ruleset,
           rules: [%{match: "weather", action: :deny, rule_id: "R-1", rationale: "blocked"}],
           default_action: :allow}
      }

      pipeline = Config.to_pipeline(bundle)
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c2", name: "weather", input: %{"city" => "NYC"}}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{
               tool_call_id: "c2",
               is_error: true,
               output: %{denied: true, rule_id: "R-1", rationale: "blocked"}
             } = result
    end

    test "before/after hooks set on the bundle reach the chokepoint" do
      redact = fn _config, _call, %ToolResult{} = r -> %{r | output: "REDACTED"} end
      bundle = %Config{after_hooks: [redact]}

      pipeline = Config.to_pipeline(bundle)
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c3", name: "weather", input: %{"city" => "NYC"}}

      assert %ToolResult{output: "REDACTED"} = Dispatch.dispatch_one(config, call, pipeline)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/config_test.exs`
Expected: FAIL — `module Normandy.Behaviours.Config is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/normandy/behaviours/config.ex
defmodule Normandy.Behaviours.Config do
  @moduledoc """
  Explicit, per-agent selection of the pluggable behaviours.

  One `{module, opts}` ref per behaviour plus the two first-class hook lists.
  Carried on `BaseAgentConfig.behaviours`; defaults to the all-defaults bundle,
  so the "everything off" path is observably identical to today.

  `to_pipeline/1` adapts the **dispatch-path** slots (`policy`, `budget`,
  `before_hooks`, `after_hooks`) into a `%Normandy.Agents.Dispatch.Pipeline{}`.
  Building it here (not on `Dispatch`) keeps the Phase 1 chokepoint untouched —
  the dependency points Phase 2 → Phase 1. The `credential` and `model_catalog`
  slots are not dispatch-path concerns and are not placed on the pipeline.
  """

  alias Normandy.Agents.Dispatch.Pipeline
  alias Normandy.Behaviours.BudgetTracker
  alias Normandy.Behaviours.CredentialProvider
  alias Normandy.Behaviours.ModelCatalog
  alias Normandy.Behaviours.PolicyEngine
  alias Normandy.Tools.Executor

  @type ref :: {module(), keyword()}
  @type hook :: (term(), term() -> term()) | (term(), term(), term() -> term())
  @type t :: %__MODULE__{
          policy: ref(),
          budget: ref(),
          before_hooks: [hook()],
          after_hooks: [hook()],
          credential: ref(),
          model_catalog: ref()
        }

  defstruct policy: {PolicyEngine.AllowAll, []},
            budget: {BudgetTracker.NoOp, []},
            before_hooks: [],
            after_hooks: [],
            credential: {CredentialProvider.FromClient, []},
            model_catalog: {ModelCatalog.Static, []}

  @doc """
  Builds a `%Dispatch.Pipeline{}` from the dispatch-path slots of the bundle.

  `nil` resolves to the default bundle. `execute_fn` is set to the bare executor
  (matching `Dispatch.default_pipeline/0`); callers that need telemetry (e.g.
  `BaseAgent`) override `execute_fn` after building.
  """
  @spec to_pipeline(t() | nil) :: Pipeline.t()
  def to_pipeline(nil), do: to_pipeline(%__MODULE__{})

  def to_pipeline(%__MODULE__{} = bundle) do
    {policy_mod, policy_opts} = bundle.policy
    {budget_mod, _budget_opts} = bundle.budget

    %Pipeline{
      before_hooks: bundle.before_hooks,
      after_hooks: bundle.after_hooks,
      policy_fn: fn config, call, tool ->
        policy_mod.check(call, %{config: config, tool: tool, opts: policy_opts})
      end,
      budget_check_fn: fn config, call ->
        budget_mod.check(scope(config), call)
      end,
      budget_record_fn: fn config, _call, result ->
        budget_mod.record(scope(config), result)
      end,
      execute_fn: fn _config, tool, _name -> Executor.execute_tool(tool) end
    }
  end

  defp scope(config) do
    %{agent: Map.get(config, :name), model: Map.get(config, :model)}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/config_test.exs`
Expected: PASS (all Config tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/config.ex test/behaviours/config_test.exs
git commit -m "feat(behaviours): add Config bundle and to_pipeline/1 chokepoint builder"
```

---

## Task 8: wire the bundle into BaseAgentConfig + BaseAgent

**Files:**
- Modify: `lib/normandy/agents/base_agent_config.ex` (`@type t` at `:14-38`; `schema do` at `:40-64`)
- Modify: `lib/normandy/agents/base_agent.ex` (`init/1` struct at `:89-115`; `base_agent_pipeline/0` at `:1203-1205`; `execute_one_tool_call/2` at `:1216-1218`; `execute_one_streaming_tool_call/2` at `:1223-1225`)

This is the parity-critical task: with the default (`nil`) bundle, the built pipeline equals today's `base_agent_pipeline/0`, so the full agent suite is the oracle.

- [ ] **Step 1: Add the `behaviours` field to BaseAgentConfig**

In `lib/normandy/agents/base_agent_config.ex`, add to the `@type t` map (after `output_guardrails_chunk_size: pos_integer()`):

```elixir
          output_guardrails_chunk_size: pos_integer(),
          behaviours: Normandy.Behaviours.Config.t() | nil
```

(Insert a comma after the existing last entry.) Then add to the `schema do` block (after the `output_guardrails_chunk_size` field):

```elixir
    field(:behaviours, :any, default: nil)
```

- [ ] **Step 2: Thread `behaviours` through `init/1` and build the pipeline from it**

In `lib/normandy/agents/base_agent.ex`, add to the `%BaseAgentConfig{...}` struct in `init/1` (after `output_guardrails_chunk_size: chunk_size`):

```elixir
      output_guardrails_chunk_size: chunk_size,
      behaviours: Map.get(config, :behaviours, nil)
```

Replace `base_agent_pipeline/0` (currently `:1203-1205`) with a `/1` that builds from the config's bundle (telemetry still overrides `execute_fn`):

```elixir
  # The chokepoint pipeline BaseAgent uses: the agent's selected behaviours
  # (default bundle = allow-all policy, no-op budget, no hooks) adapted into a
  # %Dispatch.Pipeline{}, plus a telemetry-instrumented execute_fn so tool spans
  # keep nesting under the agent.run span. With the default (nil) bundle this is
  # byte-identical to the pre-Phase-2 default_pipeline/0 + span_execute path.
  defp base_agent_pipeline(config) do
    %{
      Normandy.Behaviours.Config.to_pipeline(config.behaviours)
      | execute_fn: &span_execute/3
    }
  end
```

Update both dispatch sites to pass `config` to the builder. Replace `execute_one_tool_call/2` (currently `:1216-1218`):

```elixir
  defp execute_one_tool_call(config, tool_call) do
    Dispatch.dispatch_one(config, tool_call, base_agent_pipeline(config))
  end
```

and `execute_one_streaming_tool_call/2` (currently `:1223-1225`):

```elixir
  # Streaming-loop variant: tool_call is a string-keyed map (raw LLM JSON).
  # Dispatch.dispatch_one/3 normalizes it into a %ToolCall{} before running the
  # same chokepoint pipeline as the non-streaming path.
  defp execute_one_streaming_tool_call(config, tool_call) do
    Dispatch.dispatch_one(config, tool_call, base_agent_pipeline(config))
  end
```

- [ ] **Step 3: Run the full agent suite (parity oracle)**

Run: `mix format && mix test test/normandy/agents/ test/agents/`
Expected: PASS — all existing BaseAgent + dispatch tests green. The default bundle reproduces the prior pipeline, so non-streaming and streaming tool execution behave identically.

- [ ] **Step 4: Add a test pinning that a custom bundle flows from init to the pipeline**

Append to `test/behaviours/config_test.exs` (a new `describe` inside the module):

```elixir
  describe "BaseAgent integration" do
    test "init/1 stores a supplied behaviours bundle on the config" do
      bundle = %Config{
        policy: {PolicyEngine.Ruleset, rules: [%{match: "*", action: :allow}], default_action: :allow}
      }

      config =
        Normandy.Agents.BaseAgent.init(%{
          client: %Normandy.LLM.ClaudioAdapter{api_key: "sk-test"},
          model: "claude-3-5-sonnet-20241022",
          temperature: 0.0,
          behaviours: bundle
        })

      assert config.behaviours == bundle
    end

    test "init/1 defaults behaviours to nil (resolved to defaults at pipeline build)" do
      config =
        Normandy.Agents.BaseAgent.init(%{
          client: %Normandy.LLM.ClaudioAdapter{api_key: "sk-test"},
          model: "claude-3-5-sonnet-20241022",
          temperature: 0.0
        })

      assert config.behaviours == nil
      assert %Pipeline{} = Config.to_pipeline(config.behaviours)
    end
  end
```

- [ ] **Step 5: Run the new integration test**

Run: `mix format && mix test test/behaviours/config_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/base_agent_config.ex lib/normandy/agents/base_agent.ex test/behaviours/config_test.exs
git commit -m "feat(base_agent): select pluggable behaviours via config.behaviours bundle"
```

---

## Task 9: version bump + CHANGELOG

**Files:**
- Modify: `mix.exs` (`@version` at `:4`)
- Modify: `CHANGELOG.md` (`## [Unreleased]` at `:8`)

- [ ] **Step 1: Bump the version**

In `mix.exs`, change `@version "0.6.3"` to:

```elixir
  @version "0.7.0"
```

- [ ] **Step 2: Add the CHANGELOG entry**

In `CHANGELOG.md`, replace the `## [Unreleased]` line (`:8`) with:

```markdown
## [Unreleased]

## [0.7.0] - 2026-06-01

### Added

- **Pluggable behaviours (Phase 2 of the harness decomposition).** The dispatch
  chokepoint's function slots are now backed by four Elixir `@behaviour`s, each
  with a default impl that preserves current behavior:
  - `Normandy.Behaviours.PolicyEngine` (`check/2`) — default `AllowAll`; plus a
    shipped `Ruleset` impl that evaluates ordered in-memory rules
    (`match` glob → `:allow | :deny | :require_approval`, first-match-wins,
    configurable `default_action`).
  - `Normandy.Behaviours.BudgetTracker` (`check/2`, `record/2`) — default `NoOp`.
  - `Normandy.Behaviours.CredentialProvider` (`get_token/2`) — default
    `FromClient` (extracts `api_key` from the client struct). Defined and
    defaulted; LLM-call consumption deferred.
  - `Normandy.Behaviours.ModelCatalog` (`get/1`, `supports?/2`,
    `context_window/1`) — default `Static`, now the single source of truth for
    `WindowManager`'s context-window limits.
- **`Normandy.Behaviours.Config`** bundle + `to_pipeline/1`, selectable per-agent
  via the new `BaseAgentConfig.behaviours` field. `before/after` hooks are now
  first-class, config-selectable function slots.

### Notes

- Additive and default-off: with the default bundle, observable behavior is
  unchanged. No migration required.
```

- [ ] **Step 3: Compile and run the full suite**

Run: `mix format && mix compile --warnings-as-errors --force && mix test`
Expected: compiles clean; full suite PASSES.

- [ ] **Step 4: Commit**

```bash
git add mix.exs CHANGELOG.md
git commit -m "chore(release): cut v0.7.0 (pluggable behaviours)"
```

---

## Task 10: full-suite verification and gates

**Files:** none (verification only)

- [ ] **Step 1: Format**

Run: `mix format`

- [ ] **Step 2: Full suite**

Run: `mix test`
Expected: ALL tests pass (existing + new `test/behaviours/*`). Record the summary line (e.g. "N tests, 0 failures").

- [ ] **Step 3: Compile clean (warnings-as-errors, forced)**

Run: `mix compile --warnings-as-errors --force`
Expected: no warnings (in particular, every `@impl true` matches a declared `@callback`, and no unused `@behaviour` aliases).

- [ ] **Step 4: Commit any formatting changes**

```bash
git status --short
# if mix format changed files, add them individually, e.g.:
git add lib/normandy/behaviours/config.ex
git commit -m "chore(behaviours): format"
```

---

## Self-Review (completed during planning)

**Spec coverage (Phase 2 design → tasks):**
- Four `@behaviour`s + default impls preserving current behavior → Tasks 1, 3, 4, 5. ✓
- `PolicyEngine.Ruleset` shipped; YAML loader deferred → Task 2 (in-memory rules; deferral documented in moduledoc + CHANGELOG). ✓
- Behaviours fill chokepoint slots via builder; `dispatch.ex` untouched → Task 7 (`Config.to_pipeline/1`; no edit to `dispatch.ex`). ✓
- Explicit per-agent selection via one bundle field on `BaseAgentConfig` → Task 8. ✓
- `before/after` hooks first-class (config-selectable, contract-tested) → Task 7 (hook routing test) + Task 8 (settable via bundle). ✓
- Credential/ModelCatalog off the dispatch path; not on the Pipeline → Task 7 (`to_pipeline/1` adapts only policy/budget/hooks). ✓
- `ModelCatalog.Static` single source for `WindowManager` limits; struct shape unchanged; WindowManager tests as oracle → Task 6. ✓
- CredentialProvider defined/defaulted, consumption deferred → Task 4 (no `Model.converse` edit). ✓
- Default-off parity (existing suite is the oracle) → Tasks 6, 8 run the existing suites; Task 7 asserts `to_pipeline(default) ≈ default_pipeline/0`. ✓
- Non-breaking `0.6.3 → 0.7.0` + CHANGELOG → Task 9. ✓
- Gates: `mix format` before tests, full suite green, `mix compile --warnings-as-errors --force` clean → Tasks 9, 10. ✓
- **Deferred (own phases):** YAML loader; CredentialProvider LLM-call wiring; ModelCatalog turn-loop/compaction consumption (Phase 5); real approval parking (Phase 4); SessionStore (Phase 3).

**Placeholder scan:** none — every code step contains complete code.

**Type/name consistency:**
- `PolicyEngine.check(call, ctx)` → `{:allow, map} | {:deny, map} | {:needs_approval, map}` consistent across Tasks 1, 2, 7 and the chokepoint's `denial_result/3` (`info.reason/.rule_id/.rationale`).
- `BudgetTracker.check(scope, est)` / `record(scope, usage)` consistent across Task 3 and the `to_pipeline/1` adapters in Task 7 (`budget_check_fn(config, call)` → `check(scope(config), call)`; `budget_record_fn(config, _call, result)` → `record(scope(config), result)`), matching the existing `%Dispatch.Pipeline{}` slot arities (`budget_check_fn/2`, `budget_record_fn/3`).
- `CredentialProvider.get_token(provider, opts)` consistent (Task 4).
- `ModelCatalog` `get/1`, `supports?/2`, `context_window/1`, `limits/0` consistent across Tasks 5, 6.
- `Config` struct fields (`policy`, `budget`, `before_hooks`, `after_hooks`, `credential`, `model_catalog`) and `to_pipeline/1` consistent across Tasks 7, 8.
- `%Dispatch.Pipeline{}` fields used (`before_hooks`, `after_hooks`, `policy_fn`, `budget_check_fn`, `budget_record_fn`, `execute_fn`) match `lib/normandy/agents/dispatch.ex`. `ToolCall` (`id`, `name`, `input`) and `ToolResult` (`tool_call_id`, `output`, `is_error`) match their component modules.
- `base_agent_pipeline/0` → `base_agent_pipeline/1` rename applied at both call sites (Task 8).
