# Phase 3 — SessionStore + Branching AgentMemory

**Status:** Design approved, ready for planning
**Date:** 2026-06-01
**Parent:** `docs/superpowers/specs/2026-05-29-harness-decomposition-design.md` (feature #5)
**Predecessors:** Phase 1a–1d (dispatch chokepoint, pure Turn FSM, streaming cutover)
— PRs #24, #25. Phase 2 (pluggable behaviours) — PR #27.

## Goal

Deliver feature #5 of the harness decomposition: turn `AgentMemory` from a linear
reverse-prepend list into a **struct of parent-linked entries** (so branching /
forks / resume become expressible), and define `Normandy.Behaviours.SessionStore`
as the persistence seam — the same seam Phase 4 (#3, suspendable turn) will use to
hold suspended-turn and passivated-session state.

This is the **1.0.0 cut**. Breaking the public *shape* of `AgentMemory` (struct
fields, `dump/1`/`load/1` format, white-box unit tests) is in scope and embraced.
What is **not** broken is the **linear-conversation observable behavior**: with the
default (in-struct) path and no branching, `history/1`'s output and multi-turn
agent behavior are byte-identical to today. The existing end-to-end suite is the
**correctness oracle** that proves the entry-graph rewrite did not silently change
how agents behave. Branching is a strict *superset* added on top.

## Non-Goals (this phase)

- **No turn-loop consumption of `SessionStore`.** The default path keeps memory
  **in-struct on `config.memory`**, process-free, exactly as today. `SessionStore`
  is defined, defaulted, and contract-tested, but `base_agent` does not route
  memory through it. The consumer is Phase 4 passivation/suspend (mirrors Phase 2
  shipping `CredentialProvider` as contract+default with consumption deferred).
- **No `%TurnState{}`.** It does not exist until Phase 4. `save_turn_state` /
  `load_turn_state` are defined and contract-tested against an **opaque term**
  payload — no real consumer this phase.
- **No Postgres store / no `ecto`/`postgrex` dependency.** Deferred until a
  durable/cross-node consumer is real (as the design deferred Horde/syn and Phase 2
  deferred `yaml_elixir`).
- **No `:gen_statem` shell, no passivation, no pluggable session registry.** All
  Phase 4.
- **No Turn FSM changes.** `turn.ex` / `turn/driver.ex` are frozen. Phase 3 touches
  `AgentMemory`, adds the `SessionStore` behaviour + impls, and makes four
  **behavior-preserving** edits to consumers that reach into the old internal list
  shape (`base_agent.ex` `pending_tool_call_count/1` + `completed_iterations/1`;
  `window_manager.ex` + `summarizer.ex` `rebuild_memory*`) — see Key Insight. The
  pure Turn FSM never observes `AgentMemory`'s internals and is untouched.

## Key Insight

Most consumers of `AgentMemory` touch memory **only through the public API**
(`new_memory`, `add_message/3`, `history/1`, `count_messages/1`, `initialize_turn/1`,
`get_current_turn_id/1`) — `token_counter.ex` and the read paths of
`window_manager.ex` / `summarizer.ex` are in this group and need no change.

**Four sites reach into the internal `history` list and must be migrated** (a
codebase sweep, not an assumption — `grep` for internal-field access found exactly
these):

| Site | What it does today | Why it breaks | Behavior-preserving fix |
|---|---|---|---|
| `base_agent.ex:1316` `pending_tool_call_count/1` | matches `%{history: [latest \| _]}` to read the **newest** message's `:tool_calls` count | no `history` field on the struct | new `latest_message/1` accessor |
| `base_agent.ex:1325` `completed_iterations/1` | reads `%{history: history}`, finds the newest assistant `turn_id`, counts that turn's assistant messages | same | new `messages/1` accessor (order-robust rewrite) |
| `window_manager.ex:359` `rebuild_memory/2` | builds a bare `%{max_messages, history: [], current_turn_id}` map, reduces `add_message` over it | `add_message` pattern-matches `%AgentMemory{}`; bare map crashes | build via `new_memory/1` + struct-update `current_turn_id` |
| `summarizer.ex:217` `rebuild_memory_with_summary/4` | same bare-map construction | same | same |

Plus white-box **test** coupling to the old `.history` field: the rewritten unit
tests in `test/components/agent_memory_test.exs`, and **~21 sites across 8 further
test files** (`dsl/agent_test.exs`, `integration/agent_context_management_test.exs`,
`normandy_integration/dsl_comprehensive_test.exs`,
`integration/agent_resilience_integration_test.exs`, `agents/base_agent_tool_loop_test.exs`,
`integration/llm_caching_integration_test.exs`,
`integration/agent_tool_execution_flow_test.exs`,
`agents/base_agent_streaming_guardrails_test.exs`) that read `agent.memory.history`
directly — `length(...)`, `Enum.find/filter/all` by role, one LIFO-ordered
`Enum.reverse |> filter`. All migrate behavior-preservingly to `count_messages/1`
(counts) or `messages/1` (chronological `[%Message{}]`).

**Staging — PREP then SWAP** (keeps every commit green): **PREP** adds `messages/1`
+ `latest_message/1` to the *current* list-based `AgentMemory` and migrates the two
`base_agent` pattern-matches and all white-box test sites onto the public API — no
struct change, full suite green. **SWAP** then changes the representation to the
entry graph behind the now-stable public API and migrates the two
`rebuild_memory*` bare-map constructions. The SWAP commit's green suite is the
parity proof.

The entry-graph rewrite is otherwise internal: as long as the public functions and
the three new accessors produce identical observable output for a linear
conversation, the turn loop behaves identically. A **linear conversation is a
degenerate single-parent chain** in the entry graph; `history/1` walks `head → root`
via `parent_id`, reverses to chronological order, and maps each entry exactly as
today. The reconstruction is provably identical because the graph degenerates to
the same sequence. Branching (`fork/2`) only *adds* reachable structure; it never
changes the linear walk. The four migrated sites preserve observable behavior, and
the end-to-end suite (which drives the turn loop) is the oracle proving it.

`SessionStore` is a separate concern from the `AgentMemory` *data structure*:
`AgentMemory` is pure data + pure functions (what `config.memory` holds);
`SessionStore` is a stateful `@behaviour` for externalizing a session's entries +
turn-state across process/node boundaries. Phase 3 ships both, but only the data
structure has a real consumer — the store's consumer is deferred to Phase 4.

## Architecture

### `AgentMemory` becomes a struct of parent-linked entries

```elixir
defmodule Normandy.Components.AgentMemory.Entry do
  defstruct [:id, :parent_id, :turn_id, :role, :content]
  @type t :: %__MODULE__{
          id: String.t(),                 # UUID, unique per entry
          parent_id: String.t() | nil,    # nil for a root entry
          turn_id: String.t(),            # the turn this entry belongs to
          role: String.t(),
          content: struct() | map() | list()
        }
end

defmodule Normandy.Components.AgentMemory do
  defstruct entries: %{}, head: nil, current_turn_id: nil, max_messages: nil
  @type t :: %__MODULE__{
          entries: %{String.t() => Entry.t()},  # id => entry
          head: String.t() | nil,               # tip of the active branch
          current_turn_id: String.t() | nil,
          max_messages: pos_integer() | nil
        }
end
```

- **`head`** is the id of the most-recently-appended entry on the active branch —
  where the next `add_message` links. It is the new branching concept and is
  **orthogonal to `current_turn_id`** (which still tags entries by turn for
  `add_message`, exactly as today).
- **`entries`** is a map for O(1) lookup by id; branches coexist in one map.

### Public API — preserved signatures, identical linear behavior

| Function | Linear behavior (the oracle) | Entry-graph implementation |
|---|---|---|
| `new_memory/0,1` | `%AgentMemory{}` with `max_messages` | empty `entries`, `head: nil` |
| `initialize_turn/1` | mints fresh `current_turn_id` (UUID) | unchanged; `head` untouched |
| `add_message/3` | appends `{turn_id, role, content}`; inits turn if none; enforces `max_messages` | new `Entry{id, parent_id: head, turn_id, role, content}`; `head := id`; trim active chain to `max_messages` |
| `history/1` | chronological `[%{role, content: to_json}]` | walk `head → root`, reverse, map (no re-window — cap is enforced at write) |
| `get_current_turn_id/1` | `current_turn_id` | unchanged |
| `count_messages/1` | total messages | `map_size(entries)` (linear: every entry is the conversation) |
| `delete_turn/2` | reject messages by `turn_id`; raise `NonExistentTurn` if none | **splice** (Decision 3) |
| `dump/1` / `load/1` | JSON via adapter | extended explicit encode/decode (Decision 4) |

**New (additive) API:**

- `fork/2` — `fork(memory, from_entry_id) :: {:ok, t()} | {:error, :no_such_entry}`.
  Returns memory with `head := from_entry_id`; subsequent `add_message` appends a
  sibling branch under that entry. Branches coexist in `entries`.
- `entries/1`, `get_entry/2` — read accessors for branch-aware callers (the legacy
  `history/1` linear view is unchanged).
- `entry_chain/1 :: [Entry.t()]` — the active branch `head → root`, returned
  **chronological** (oldest → newest). The shared internal walk that `history/1`,
  `messages/1`, and the `SessionStore` impls all build on (DRY).
- `messages/1 :: [Message.t()]` — `entry_chain/1` mapped to `%Message{turn_id, role,
  content}` (chronological). Backs the `completed_iterations/1` migration.
- `latest_message/1 :: Message.t() | nil` — the newest message (the `head` entry as
  a `%Message{}`), or `nil` when empty. Backs the `pending_tool_call_count/1`
  migration.

`history/1` is `messages/1 |> Enum.map(&%{role: &1.role, content: to_json(&1.content)})`
— identical output to today.

`max_messages` keeps today's **destructive write-time cap** on the active chain:
after `add_message`, if the active `head → root` chain exceeds `max_messages`, the
oldest entries on that chain are dropped and the chain re-rooted (`parent_id := nil`
on the new oldest). On a pure-linear conversation this is byte-identical to today
(`count_messages` and `history/1` match the overflow/limit-zero/no-limit tests).
Capping policy across *multiple* branches is out of scope (branching is opt-in;
the cap applies to the active chain).

### `Normandy.Behaviours.SessionStore` — the persistence seam

```elixir
@type handle :: term()        # impl-specific: pid (InMemory), table (ETS)
@type session_id :: String.t()

@callback append_entry(handle, session_id, Entry.t()) :: {:ok, String.t()} | {:error, term}
@callback history(handle, session_id) :: {:ok, [Entry.t()]} | {:error, term}
@callback fork(handle, session_id, from_entry_id :: String.t()) ::
            {:ok, session_id} | {:error, term}
@callback save_turn_state(handle, session_id, state :: term) :: :ok | {:error, term}
@callback load_turn_state(handle, session_id) :: {:ok, term} | :error
```

All **five** callbacks are defined now (Decision 2). The contract test suite obtains
a fresh handle per impl via a `new/1` (or `start_link/1`) convention each impl
exposes for test setup; the behaviour itself stays the five data callbacks.

**Invariants the shared contract pins (impl-agnostic):**

- `append_entry` then `history` returns the chain in chronological order; the
  returned entry id round-trips.
- `fork(h, sid, e)` yields a reference whose `history` is the **ancestor chain up
  to and including `e`**; appends to the fork do **not** affect the original branch,
  and appends to the original do not affect the fork.
- `save_turn_state` then `load_turn_state` round-trips an **arbitrary opaque term**
  unchanged; `load_turn_state` on an unsaved session returns `:error`.

### Store implementations shipped

| Impl | Backing | Role |
|---|---|---|
| `SessionStore.InMemory` | a started process (`Agent`) holding `%{session_id => …}` | reference + contract impl; the default bundle selection |
| `SessionStore.ETS` | a named ETS table | fast in-node; resolves parent Open-Q #1 (proven in-node default, ready for Phase 4) |
| ~~`SessionStore.Postgres`~~ | — | **deferred** (no `ecto`/`postgrex` dep until a real consumer) |

Two impls keep the contract honest — the same suite runs against both, so no
in-memory assumption leaks into the contract. Neither is **consumed** by the turn
loop this phase.

### Decision 1 — Linear path stays observably identical (degenerate chain)

`history/1` over a linear conversation produces the exact `[%{role, content}]` list
it does today, because the entry graph degenerates to the same `head → root`
sequence. This is the correctness oracle: the existing end-to-end suite passes
unchanged in observable output. Breaking the *struct shape* / *dump format* /
*unit tests* is fine for 1.0; breaking linear *behavior* is not — branching is a
superset, not a mutation. (`base_agent`'s `build_streaming_assistant_response`
tool_use re-serialization depends on `history/1`'s output and is therefore
untouched.)

### Decision 2 — Define all five callbacks; defer the turn-state consumer

`SessionStore` defines and contract-tests all five callbacks now, including
`save_turn_state` / `load_turn_state` against an **opaque term** (since
`%TurnState{}` is Phase 4). Defining the complete contract once means Phase 4 never
reopens the `@behaviour`; round-tripping an opaque term proves the seam works for
whatever `%TurnState{}` becomes. This mirrors Phase 2 exactly (`CredentialProvider`
/ `ModelCatalog` defined + defaulted + contract-tested, consumption deferred).

### Decision 3 — `delete_turn/2` splices on the graph

`delete_turn(memory, turn_id)` removes every entry whose `turn_id` matches and
**re-parents their children to the deleted entry's parent** (splice), keeping the
graph connected with no orphans. Raises `Normandy.NonExistentTurn` when no entry
matches (unchanged). On a linear chain this is byte-identical to today's "reject
messages with this `turn_id` from the list." `current_turn_id` is unaffected; if
the deleted entries included `head`, `head` moves to the spliced parent.

### Decision 4 — `dump`/`load` is explicit JSON encode/decode (parent Open-Q #2)

Keep the human-readable, adapter-driven format; **reject `:erlang.term_to_binary`**
(brittle across code changes; a load-time security footgun on untrusted input —
arbitrary atom/term creation). Extend today's `%{type, data}` content wrapper to
entries:

```json
{
  "version": 1,
  "max_messages": null,
  "current_turn_id": "…",
  "head": "entry-uuid-or-null",
  "entries": [
    {"id": "…", "parent_id": null, "turn_id": "…", "role": "user",
     "content": {"type": "Elixir.Some.Struct", "data": {…}}}
  ]
}
```

- Struct content → `%{type: to_string(__struct__), data: struct}`; loaded via
  `String.to_existing_atom/1` + `struct/2` (as today).
- Non-struct content (plain map / list — used by the list-shaped-content path) →
  `%{type: "raw", data: content}`; loaded verbatim. (Today's `dump/1` only handled
  struct content; this is a clean 1.0 improvement.)
- `load/1` reconstructs `entries`, `head`, `current_turn_id`, `max_messages`. **No
  legacy-format loading** — clean 1.0 cut; old linear dumps are not supported.

### Decision 5 — Store selection is a 7th slot on `Normandy.Behaviours.Config`

```elixir
%Normandy.Behaviours.Config{
  policy:        {PolicyEngine.AllowAll, []},
  budget:        {BudgetTracker.NoOp, []},
  before_hooks:  [],
  after_hooks:   [],
  credential:    {CredentialProvider.FromClient, []},
  model_catalog: {ModelCatalog.Static, []},
  session_store: {SessionStore.InMemory, []}   # NEW — selectable, not consumed yet
}
```

`session_store` rides the bundle exactly like `credential` / `model_catalog`:
selectable per-agent, **not** placed on the dispatch `Pipeline` (`to_pipeline/1`
ignores it — it is not a dispatch-path concern). It is **wired but not consumed**
in Phase 3 (Phase 2 set the precedent of adding slots ahead of their consumer);
the default selection starts no process on the default path. Phase 4's shell reads
this slot to choose where suspended/passivated state lives.

### Resolves parent-design open questions

- **Open-Q #1 (ETS vs Postgres default):** ETS is an acceptable in-node default;
  ship `InMemory` + `ETS` now, **defer Postgres** until a durable/cross-node
  consumer exists. Teams needing cross-node/durable sessions supply their own store
  or the future Postgres reference impl.
- **Open-Q #2 (term vs explicit serialization):** **explicit encode/decode** via
  the JSON adapter (Decision 4), not `term_to_binary`.

## Data flow

**Linear turn (default, parity path) — unchanged observably:**

1. `base_agent` holds `%AgentMemory{}` on `config.memory` (in-struct, no store, no
   process).
2. `add_message/3` appends an `Entry` linked to `head`; `head` advances.
3. `history/1` walks `head → root`, reverses, maps to `[%{role, content: to_json}]`
   — identical to today; the LLM sees the same messages. (The `max_messages` cap is
   already applied destructively at write time, as today; `history/1` does not
   re-window.)

**Branching (opt-in, new):**

1. `fork(memory, entry_id)` → `head := entry_id`.
2. `add_message/3` appends a sibling branch under `entry_id`; the original branch's
   entries remain reachable in `entries`.
3. `history/1` reflects the *active* branch (from the new `head`).

**Store (defined, contract-tested, unconsumed):** an impl is started in tests,
`append_entry`/`history`/`fork` exercise the entry-graph round-trip,
`save_turn_state`/`load_turn_state` round-trip an opaque term.

## Testing strategy

- **Linear parity (the oracle):** the full existing suite passes unchanged in
  observable output with the in-struct default path. `agent_memory_test.exs` is
  rewritten for the entry struct, but its *assertions on `history/1` output*
  (including the list-shaped-content and dump/load round-trip cases) keep the same
  expected values.
- **Entry-graph unit tests:** `add_message` links to `head`; `history` walks the
  chain; `max_messages` destructive cap on the active chain (overflow / limit-zero /
  no-limit); `delete_turn` splice (linear == today; branched re-parents children;
  `NonExistentTurn` on miss); `dump`/`load` round-trip for struct and raw content.
- **Branching tests:** `fork` then `add_message` produces divergent branches;
  `history/1` follows the active `head`; original branch entries stay reachable.
- **`SessionStore` shared contract suite:** one ExUnit module run against both
  `InMemory` and `ETS`, pinning the invariants above (append/history order, fork
  isolation, opaque turn-state round-trip, `load_turn_state` `:error` on miss).
- **`Config` slot:** default bundle carries `session_store: {InMemory, []}`;
  `to_pipeline/1` is **unchanged** (asserts the slot does not leak onto the
  `Pipeline`) — the Phase 2 equivalence test still holds.
- **Gates:** `mix format` → `mix compile --warnings-as-errors --force` clean →
  `mix test` full suite green (baseline: 71 doctests, 25 properties, 1162 tests,
  0 failures, 13 skipped).

## Risks & Mitigations

- **`history/1` linear output drifting from today.** Mitigated by keeping the
  expected values in the rewritten `agent_memory_test.exs` and by the full
  end-to-end suite as the oracle; the degenerate-chain walk must reproduce today's
  list exactly before any branching code is trusted.
- **`max_messages` destructive cap mishandled on the graph.** Mitigated by scoping
  the cap to the active chain and pinning the three overflow tests as the oracle.
- **`SessionStore` contract baking in `InMemory` assumptions.** Mitigated by
  running the same suite against `ETS` as well; two impls force an honest contract.
- **Scope creep into Phase 4 (gen_statem, passivation, `%TurnState{}`).** Explicitly
  deferred; the store's turn-state half is opaque-term contract-tested only.
- **Scope creep into a Postgres dependency.** Explicitly deferred; no `ecto`/
  `postgrex` in the tree this phase.

## Deliverables

1. `Normandy.Components.AgentMemory.Entry` struct.
2. `Normandy.Components.AgentMemory` rewritten as the entry-graph struct: preserved
   public API (`new_memory`, `initialize_turn`, `add_message`, `history`,
   `get_current_turn_id`, `count_messages`, `delete_turn`, `dump`, `load`) with
   identical linear behavior; additive `fork/2`, `entries/1`, `get_entry/2`,
   `entry_chain/1`, `messages/1`, `latest_message/1`; explicit JSON `dump`/`load`
   (struct + raw content).
2b. Four behavior-preserving consumer migrations off the old internal list shape:
   `base_agent.ex` `pending_tool_call_count/1` (→ `latest_message/1`) and
   `completed_iterations/1` (→ `messages/1`); `window_manager.ex` `rebuild_memory/2`
   and `summarizer.ex` `rebuild_memory_with_summary/4` (bare-map construction →
   `new_memory/1` + `current_turn_id` struct-update).
3. `Normandy.Behaviours.SessionStore` `@behaviour` (five callbacks).
4. `SessionStore.InMemory` (default) + `SessionStore.ETS`; Postgres deferred.
5. `session_store` slot on `Normandy.Behaviours.Config` (selectable, not consumed;
   `to_pipeline/1` unchanged).
6. Rewritten `agent_memory_test.exs`; entry-graph + branching unit tests; the
   shared `SessionStore` contract suite run against `InMemory` and `ETS`; full suite
   green; compile clean.
7. CHANGELOG note + `1.0.0` version bump + a short migration note for the
   `AgentMemory` struct / `dump`-`load` format change.
