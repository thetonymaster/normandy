# Phase 2 — Pluggable Behaviours

**Status:** Design approved, ready for planning
**Date:** 2026-06-01
**Parent:** `docs/superpowers/specs/2026-05-29-harness-decomposition-design.md`
**Predecessors:** Phase 1a–1d (dispatch chokepoint, pure Turn FSM, non-streaming +
streaming cutover) — merged in PRs #24, #25.

## Goal

Turn the `%Dispatch.Pipeline{}`'s anonymous-function slots (`policy_fn`,
`budget_check_fn`, `budget_record_fn`, `before_hooks`, `after_hooks`) into real
Elixir `@behaviour`s with **selectable default implementations that preserve
current behavior**, and define two further LLM-call-level behaviours
(`CredentialProvider`, `ModelCatalog`) the parent design lists for this phase.

With every behaviour at its default, the existing end-to-end suite is the parity
oracle: observable output is byte-identical to today. Behaviour selection is
**explicit, per-agent, via config** — never implicit last-registration-wins.

## Non-Goals (this phase)

- **No Turn FSM changes.** `turn.ex` and `turn/driver.ex` are frozen. Behaviours
  attach at the existing chokepoint (`Dispatch.dispatch_one/3`) and at the
  bundle on `BaseAgentConfig`; the pure core never observes them.
- **No `dispatch_one/3` or `%Dispatch.Pipeline{}` struct change.** Behaviours
  *fill* the existing function slots via a builder; the exercised chokepoint code
  is untouched.
- **No LLM-call rewiring for credentials.** `CredentialProvider` is defined,
  defaulted, and contract-tested, but the token still flows through
  `config.client` exactly as today (see Decision 4). Consumption is deferred.
- **No turn-loop consumption of `ModelCatalog`.** Compaction (Phase 5) is the
  consumer. This phase makes `ModelCatalog.Static` the single source of truth for
  `WindowManager`'s limits and nothing more.
- **No YAML file format / parser.** `PolicyEngine.Ruleset` evaluates in-memory
  structured rules; a YAML-file loader (and its dependency) is deferred.
- **Deferred to later phases:** real approval parking (Phase 4), SessionStore /
  branching memory (Phase 3), compaction wiring (Phase 5).

## Key Insight

The chokepoint already proved the seam in Phase 1a: `dispatch_one/3` consults
behaviour *functions* carried on `%Dispatch.Pipeline{}`, defaulting to allow-all /
no-op / identity. Phase 2 does not move that seam — it gives the functions a
**named contract** (`@behaviour`) and a **named default impl**, then adapts
`{module, opts}` selections back into the same function slots. The chokepoint
cannot tell the difference between today's `default_pipeline/0` and a bundle of
all-default behaviours: that equivalence is the parity guarantee, and it is
mechanically checkable (`Config.to_pipeline(default_bundle)` must reproduce
`default_pipeline/0` + `span_execute`).

Two of the four behaviours the parent design names for this phase
(`CredentialProvider`, `ModelCatalog`) are **not dispatch-path concerns** — the
chokepoint is about tool calls; credentials and the model catalog are LLM-call
concerns with no per-tool-call seam. They are delivered as contracts + default
impls selectable on the same bundle, but they do not touch the `Pipeline`.

## Architecture

### Module layout (`Normandy.Behaviours.*`)

```
Normandy.Behaviours.Config                  # the selection bundle struct
Normandy.Behaviours.PolicyEngine            # @behaviour  check/2
  .AllowAll        (default)                #   {:allow, %{}}
  .Ruleset         (shipped, non-default)   #   ordered rules, first-match-wins
Normandy.Behaviours.BudgetTracker           # @behaviour  check/2, record/2
  .NoOp            (default)
Normandy.Behaviours.CredentialProvider      # @behaviour  get_token/2
  .FromClient      (default)                #   {:ok, client.api_key}
Normandy.Behaviours.ModelCatalog            # @behaviour  get/1, supports?/2, context_window/1
  .Static          (default)                #   canonical context-window limits
```

`Normandy.Behaviours` is a pure namespace (no struct of its own); the bundle is
`Normandy.Behaviours.Config` to avoid a module that is simultaneously a namespace
parent and a struct.

### The four `@behaviour` contracts + default impls

| Behaviour | Callback(s) | Default impl (parity) |
|---|---|---|
| `PolicyEngine` | `check(call, ctx) :: {:allow, map} \| {:deny, map} \| {:needs_approval, map}` | `AllowAll` → `{:allow, %{}}` |
| `BudgetTracker` | `check(scope, est) :: :ok \| {:error, term}` · `record(scope, usage) :: :ok` | `NoOp` → `:ok` / `:ok` |
| `CredentialProvider` | `get_token(provider, opts) :: {:ok, String.t} \| {:error, term}` | `FromClient` → `{:ok, client.api_key}` |
| `ModelCatalog` | `get(model) :: {:ok, map} \| :error` · `supports?(model, cap) :: boolean` · `context_window(model) :: pos_integer \| nil` | `Static` → hardcoded limits |

Concrete argument shapes (so the adapters in the next section are well-defined):

- **`PolicyEngine.check(call, ctx)`** — `call` is the `%ToolCall{}`; `ctx` is
  `%{config: config, tool: prepared_tool}`. `AllowAll` ignores both.
- **`BudgetTracker`** — `scope` is `%{agent: config.name, model: config.model}`;
  `est` is the `%ToolCall{}` about to run; `usage` is the produced
  `%ToolResult{}`. `NoOp` ignores all.
- **`CredentialProvider.get_token(provider, opts)`** — `provider` is the client
  struct. `FromClient` matches any client exposing a binary `:api_key`
  (`def get_token(%{api_key: k}, _opts) when is_binary(k), do: {:ok, k}`), so it
  works for `ClaudioAdapter` without a hard module dependency, and returns
  `{:error, :no_api_key}` otherwise. Never logs the token.
- **`ModelCatalog`** — `get/1` returns `{:ok, %{context_window: n, capabilities:
  [atom]}}` or `:error`; `context_window/1` returns the window or `nil` (caller
  applies its own fallback); `supports?/2` is membership in the entry's
  `capabilities`. `Static` ships one entry per model currently in
  `WindowManager`'s `model_limits`, with `capabilities: [:tools, :vision,
  :streaming]` (all true for those Claude models).

### Decision 1 — Behaviours fill the chokepoint slots via a builder

`Normandy.Behaviours.Config` carries one `{module, opts}` ref per behaviour plus
the two hook lists:

```elixir
%Normandy.Behaviours.Config{
  policy:        {PolicyEngine.AllowAll, []},
  budget:        {BudgetTracker.NoOp, []},
  before_hooks:  [],
  after_hooks:   [],
  credential:    {CredentialProvider.FromClient, []},
  model_catalog: {ModelCatalog.Static, []}
}
```

A new `Normandy.Behaviours.Config.to_pipeline/1` adapts the **dispatch-path**
slots (`policy`, `budget`, `before_hooks`, `after_hooks`) into the existing
`%Dispatch.Pipeline{}` function slots. Putting this builder on the **bundle**
(not on `Dispatch`) means `dispatch.ex` is **literally unchanged** this phase —
the dependency points Phase 2 → Phase 1 (`Behaviours.Config` knows
`Dispatch.Pipeline`), never the reverse:

```elixir
policy_fn        = fn config, call, tool -> mod.check(call, %{config: config, tool: tool}) end
budget_check_fn  = fn config, call       -> mod.check(scope(config), call) end
budget_record_fn = fn config, _call, res -> mod.record(scope(config), res) end
before_hooks     = bundle.before_hooks    # passed through (typed fn list)
after_hooks      = bundle.after_hooks      # passed through (typed fn list)
execute_fn       = &BaseAgent.span_execute/3   # telemetry preserved, unchanged
```

`opts` is threaded as a closed-over first argument when an impl needs
configuration (e.g. `Ruleset` closes over its compiled rules). `dispatch_one/3`
and the `Pipeline` struct do **not** change (`dispatch.ex` is untouched). The
`credential` and `model_catalog` slots are **not** adapted into the `Pipeline`
(Decision 4).

Rejected alternative: rewrite `%Dispatch.Pipeline{}` to carry `{module, state}`
tuples and call `module.check(...)` inside `dispatch_one/3`. It edits the
just-merged, test-covered chokepoint and loses the ability to compose arbitrary
functions, which the existing dispatch tests rely on.

### Decision 2 — Selection lives in one bundle field on `BaseAgentConfig`

Add a single field `behaviours` to `BaseAgentConfig`, defaulting to the
all-defaults bundle. `BaseAgent.init/1` leaves it at the default unless the caller
supplies one; `base_agent_pipeline/0` becomes
`%{Normandy.Behaviours.Config.to_pipeline(config.behaviours) | execute_fn:
&span_execute/3}` (telemetry still overrides `execute_fn`).

Because the default bundle reproduces today's `default_pipeline/0`, adding the
field is **additive and default-off**: existing constructors that never mention
`behaviours` get identical behavior. This is non-breaking (Decision 5).

Rejected alternatives: six flat fields on an already-large struct (scatters the
selection, no single place to read the whole set); application-env selection (not
per-agent, harder to test in isolation, conflicts with `BaseAgentConfig`'s
per-agent nature).

### Decision 3 — Hooks are first-class as typed, config-selectable fn slots

"First-class" means the before/after hooks the chokepoint already runs become:
(a) settable through the `behaviours` bundle (not just hand-built test
pipelines), (b) documented with an explicit contract, and (c) covered by tests
proving config-level hooks reach the chokepoint. The shapes are exactly what
`dispatch_one/3` already consumes:

- **before:** `(config, call) -> {:cont, %ToolCall{}} | {:halt, %ToolResult{}}`
- **after:** `(config, call, result) -> %ToolResult{}`

No fifth `Hook` `@behaviour` is introduced — the four behaviours stay four, the
parent design keeps hooks out of its #2 table, and the existing dispatch tests
already pin the plain-fn shape.

### Decision 4 — Credential / ModelCatalog placement (off the dispatch path)

Both live in the bundle and are consumed (or not) at the turn/LLM level, never on
the `Pipeline`:

- **`ModelCatalog.Static` becomes the single source of truth** for the
  context-window limits currently hardcoded in `WindowManager`
  (`window_manager.ex:46-53`). `WindowManager.for_model/2` consults
  `ModelCatalog.context_window/1` instead of duplicating the literal map.
  `WindowManager`'s public struct shape (its `model_limits` field and defaults)
  is **unchanged** so the change is non-breaking; `WindowManager`'s existing
  tests are the parity oracle for this edit. This is the only *consumption*
  `ModelCatalog` gets this phase — the turn loop still does not call it
  (compaction, Phase 5, is the turn-level consumer).

- **`CredentialProvider.FromClient` is defined, defaulted, and contract-tested,
  but its LLM-call consumption is deferred.** The token still flows through
  `config.client` into `Model.converse` exactly as today (the key lives inside
  the client struct; `BaseAgent` never touches it). Rewiring `Model.converse`
  through the provider would risk parity for a seam nothing else needs yet, so
  this phase ships the contract and default only. A later phase (credential
  rotation / multi-provider) wires consumption.

### Decision 5 — `PolicyEngine.Ruleset` (shipped, non-default; YAML deferred)

`Ruleset` evaluates an ordered list of in-memory rules, first-match-wins, with a
configurable default action:

```elixir
{PolicyEngine.Ruleset,
 rules: [
   %{match: "billing_*", action: :deny, rule_id: "R-1",
     rationale: "billing tools require human approval"},
   %{match: "*", action: :allow}
 ],
 default_action: :allow}
```

- `match` is a tool-name glob (`*` / `prefix_*` / exact). Matching is on the
  `%ToolCall{}.name`.
- `action` ∈ `:allow | :deny | :require_approval`, mapping to the chokepoint's
  `{:allow, meta}` / `{:deny, info}` / `{:needs_approval, info}`. `deny` and
  `require_approval` carry `rule_id` + `rationale` so the `DenialEnvelope`'s
  rationale is fed back into the model context (per the parent design's
  "the model learns *why*").
- `:require_approval` reaches `dispatch_one/3`'s existing interim-tagged
  `needs_approval` branch (real parking is Phase 4).
- Rules are compiled once at bundle-build time and closed over in the `opts`
  argument; `check/2` is pure.

A YAML-file loader is a thin serialization layer over this evaluator and is
deferred — it would add a dependency (`yaml_elixir`) for no capability the
in-memory evaluator lacks.

### Versioning

Phase 2 is additive and default-off, so it does **not** exercise the parent
design's "breaking changes acceptable / new major" allowance. Cut **`0.6.3` →
`0.7.0`** (minor, new feature) with a CHANGELOG note describing the `behaviours`
bundle and the four contracts. No migration guide is required because the default
path is unchanged.

## Data flow (one tool call, default bundle)

1. `BaseAgent` builds `pipeline = Config.to_pipeline(config.behaviours)` with
   `execute_fn` overridden to `span_execute/3` — for the default bundle this is
   identical to today's `default_pipeline/0` + `span_execute/3`.
2. `dispatch_one/3` runs unchanged: registry → before-hooks (none) →
   `policy_fn` (`AllowAll.check` → `{:allow, %{}}`) → `budget_check_fn`
   (`NoOp.check` → `:ok`) → `span_execute` → `budget_record_fn` (`NoOp.record`
   → `:ok`) → after-hooks (none).
3. Observable result is identical to today. Swapping in `{PolicyEngine.Ruleset,
   rules: ...}` changes only the `policy_fn`'s verdict; everything else holds.

## Testing strategy

- **Contract tests per behaviour:** a shared ExUnit module that any impl must
  pass — `AllowAll` + `Ruleset` against the `PolicyEngine` contract; `NoOp`
  against `BudgetTracker`; `FromClient` against `CredentialProvider`; `Static`
  against `ModelCatalog`.
- **Fake impls per behaviour** for injection in turn/chokepoint tests (mirrors
  the existing `dispatch_test.exs` fakes).
- **`Config.to_pipeline/1` equivalence:** assert the default bundle yields a
  `Pipeline` whose `policy_fn`/`budget_*`/hooks behave identically to
  `default_pipeline/0` (the mechanical parity check); assert non-default bundles
  route deny/approval/budget outcomes through `dispatch_one/3` correctly.
- **`Ruleset` evaluation:** first-match-wins, glob matching, default action,
  rationale/rule_id propagation into the `DenialEnvelope`.
- **`ModelCatalog` ↔ `WindowManager`:** `WindowManager`'s existing suite stays
  green after `for_model/2` sources limits from the catalog (parity oracle for
  the single-source edit); a test asserts catalog and prior literals agree.
- **Back-compat / parity oracle:** the full existing suite passes with the
  default `behaviours` bundle — observable output unchanged.
- **Gates:** `mix format` → `mix test` (full suite green) → `mix compile
  --warnings-as-errors --force` clean.

## Risks & Mitigations

- **`Config.to_pipeline/1` drifting from `default_pipeline/0`.** Mitigated by the
  equivalence test that asserts the default bundle reproduces the current pipeline
  behavior before any non-default impl is trusted.
- **`WindowManager` regression when limits move to `ModelCatalog`.** Mitigated by
  keeping `WindowManager`'s struct shape unchanged and running its existing tests
  as the oracle; the catalog must return the same numbers for the same models.
- **Scope creep into LLM-call credential wiring.** Explicitly deferred (Decision
  4); this phase ships the `CredentialProvider` contract + default only.
- **Over-building the policy engine.** Mitigated by shipping the in-memory
  `Ruleset` evaluator and deferring the YAML file format + dependency.

## Deliverables

1. `Normandy.Behaviours.PolicyEngine` + `AllowAll` + `Ruleset`.
2. `Normandy.Behaviours.BudgetTracker` + `NoOp`.
3. `Normandy.Behaviours.CredentialProvider` + `FromClient`.
4. `Normandy.Behaviours.ModelCatalog` + `Static`; `WindowManager.for_model/2`
   sources its limits from the catalog.
5. `Normandy.Behaviours.Config` bundle + `Config.to_pipeline/1` (`dispatch.ex`
   unchanged); `behaviours` field on `BaseAgentConfig`; `base_agent_pipeline/0`
   builds from it.
6. Contract tests + fakes per behaviour; `Config.to_pipeline/1` equivalence
   tests; `Ruleset` tests; full suite green; compile clean.
7. CHANGELOG note + `0.7.0` version bump.
