# Agent lifecycle hooks — design

Date: 2026-10-03. Branch: `feat/claudio-0.7-migration` (Normandy 2.0).
Source: brainstorm with Q, 2026-10-03; revised the same day after five audits
(ergonomics, performance, design, maintainability, correctness) and Q's decisions on them.

## Problem

Normandy's only hooks run around tool calls: `before_hooks` and `after_hooks` on
`Normandy.Behaviours.Config`, run by `Dispatch` (`dispatch.ex:219`, `dispatch.ex:264`). They
have two limits.

- **They are functions, so they are never persisted.** `ConfigTemplate` leaves them out of the
  template and takes them from the node-local supplement on rebuild
  (`config_template.ex:128`). Every module-based slot (`policy`, `compactor`, …) travels in
  `behaviours_refs` instead.
- **Nothing else in the lifecycle can be hooked.** An application cannot rewrite or block a
  prompt before the turn, block an LLM call, inject context when a session starts, save what
  compaction drops, or audit a turn's outcome. Telemetry observes most of these points, but
  telemetry cannot change an outcome and is not meant to run application logic.

There is also an audit gap in today's tool hooks: `after_hooks` see only results of tools that
ran (`Dispatch.execute/4`). Every other result the model reads skips them: registry misses,
invalid or schema-failing input, before-hook halts, policy and budget denials
(`dispatch.ex:209-246`, `dispatch.ex:266-268`, `dispatch.ex:302`), approval rejected and
expired (built by the pure core, `turn.ex:425`, `turn.ex:434`, appended by `Turn.Server`), and
interrupted-batch repair (`server.ex:869`).

## Decisions (approved by Q)

1. Hooks serve four purposes: guard/rewrite, inject context, save what compaction drops,
   side effects/audit.
2. A new `Normandy.Behaviours.Hooks` behaviour with optional callbacks, one per event.
3. An agent has an **ordered list** of `{module, opts}` hook entries, persisted with the
   other behaviour refs.
4. The existing `before_hooks`/`after_hooks` functions **stay** and run after the hook
   modules. They remain the node-local option for closures over runtime values.
5. Errors follow guardrails: a per-entry `:on_error` of `:reraise` (default), `:open` or
   `:closed`.
6. Approach A: hooks are called from the shared functions every shell already goes through,
   via one `Normandy.Hooks.Runner`. The pure `Turn` core does not change. `Turn.Inline` runs
   no hooks *(amended 2026-10-03: Inline has no hook site of its own; tool hooks run there
   when its `:dispatch` dep uses an agent pipeline, see §5)*.
7. Events: `on_session_start`, `on_passivate`, `on_prompt`, `before_llm`, `before_tool`,
   `after_tool`, `after_compact`, `on_turn_end`.
8. Out: a reliable `session_end` (needs `trap_exit` in `Turn.Server`), LLM request/response
   rewriting, and `before_compact` (it cannot know whether compaction will happen;
   `after_compact` receives the dropped messages instead).

Added 2026-10-03, after the audits:

9. **`after_compact` reads what the compactor reports.** The `Compactor` contract gains an
   optional `meta.dropped`: the entries the compactor removed, with their entry ids.
   `Compactor.WindowManager` and the test compactor fill it; `NoOp` is unchanged.
   `after_compact` fires only when `meta.dropped` is non-empty. There is no memory diff.
   After a rehydrate, compaction runs again and `after_compact` can fire again for the same
   messages; hooks deduplicate on entry id.
10. **No hook timeouts.** Hooks run inline, like guardrails and the policy engine; a slow hook
    stalls its turn (or, in `Turn.Server`, its session). Slow side effects hand off to their
    own process.
11. **A narrow context.** `Hooks.Context` has no `config`: `event`, `agent_name`, `model`,
    `session_id`, `turn_id`, `values` (the agent's `tool_context`). No read-only memory view:
    no audit found a concrete need. Nothing secret is in the context by construction.
12. **`on_prompt` runs after input validation.** Hooks receive the validated input. A rewrite
    is validated again (`ValidationMiddleware.validate_input/2`) before input guardrails.

Fixes Q approved with the audits (2026-10-03): every hook call in the `Turn.Server` process is
crash-isolated; `on_session_start` leaves `init/1`; logged-only events ignore return values;
`Turn.Server` replies before `on_turn_end`; `before_llm`/`after_compact` wrap the handler set
so custom `:handlers` run them; every tool result the model sees passes the module
`after_tool` exactly once; `use Normandy.Behaviours.Hooks` with compile-time checks; hook opts
are checked for plain data at `BaseAgent.init/1`; hook glue lives in small modules.

## Design

### 1. The behaviour

```elixir
defmodule Normandy.Behaviours.Hooks do
  @type opts :: keyword()
  @type entry :: {module(), opts()}
  @type outcome :: {:ok, response :: term()} | {:error, reason :: term()} | {:rejected, Exception.t()}

  @callback on_session_start(Context.t(), opts) :: {:inject, [String.t()]} | term()
  @callback on_passivate(Context.t(), opts) :: term()
  @callback on_prompt(input :: term(), Context.t(), opts) ::
              {:cont, term()} | {:halt, reason :: String.t()}
  @callback before_llm(%{final: boolean(), iterations_left: integer()}, Context.t(), opts) ::
              :cont | {:halt, reason :: String.t()}
  @callback before_tool(ToolCall.t(), Context.t(), opts) ::
              {:cont, ToolCall.t()} | {:halt, String.t() | ToolResult.t()}
  @callback after_tool(ToolCall.t(), ToolResult.t(), Context.t(), opts) :: {:cont, ToolResult.t()}
  @callback after_compact(dropped :: [AgentMemory.Entry.t()], meta :: map(), Context.t(), opts) ::
              {:inject, [String.t()]} | term()
  @callback on_turn_end(outcome(), Context.t(), opts) :: term()
  @callback validate_opts!(opts) :: term()
end
```

- Every callback is optional. `@optional_callbacks` is derived from the one `@events` list
  that `events/0` returns; a test fails if they drift.
- `use Normandy.Behaviours.Hooks` sets `@behaviour` and, at compile time, raises
  `ArgumentError` for a public function named like an event with the wrong arity
  (`before_tool/2`, the function-hook arity) and warns for a public function whose name is
  close to an event's (`on_promt`, `after_tools`; Jaro distance ≥ 0.9). A misspelled
  callback would otherwise never run, silently.
- Return values, and why they are shaped so:

  | Callback | Pass | Change | Stop | Anything else |
  |---|---|---|---|---|
  | `on_prompt` | `{:cont, input}` | `{:cont, new}` | `{:halt, String.t()}` | `ArgumentError` |
  | `before_llm` | `:cont` | — (the info is not rewritable) | `{:halt, String.t()}` | `ArgumentError` |
  | `before_tool` | `{:cont, call}` | `{:cont, new_call}` | `{:halt, String.t()}` or `{:halt, %ToolResult{}}` | `ArgumentError` |
  | `after_tool` | `{:cont, result}` | `{:cont, new_result}` | — | `ArgumentError` |
  | `after_compact`, `on_session_start` | any value | `{:inject, [String.t()]}` (`[]` injects nothing) | — | `{:inject, non_list}` raises `ArgumentError`; other values are ignored |
  | `on_turn_end`, `on_passivate` | any value (ignored) | — | — | — |

  Rewriting callbacks all answer `{:cont, value}`, so a value is never ambiguous between
  "unchanged" and "replaced"; gates that cannot rewrite answer `:cont`. A string halt is the
  common case everywhere; `before_tool` also takes a full `%ToolResult{}` for a custom error
  payload. Side-effect callbacks (`on_turn_end`, `on_passivate`, and the non-inject returns of
  `after_compact`/`on_session_start`) end with whatever the side effect returned
  (`Repo.insert/1` gives `{:ok, row}`), so their value is not checked.
- Module callbacks take `(…, ctx, opts)`; the function hooks keep `(config, call)` and
  `(config, call, result)`. The guide has a table contrasting the two.

### 2. Configuration and persistence

- `Behaviours.Config` gains `hooks: [{module(), keyword()}]`, default `[]`.
- `ConfigTemplate.from_config/2` records it in `behaviours_refs.hooks`; `rebuild/3` restores
  it without checking it. A template saved before the field existed rebuilds with `[]`.
- `Normandy.DSL.Agent` gains a `hooks [{Mod, opts}, …]` declaration. A second declaration in
  one agent raises. Declared entries run before entries given in `new/1`'s `behaviours:`.
- **Validation** (`Hooks.validate_entries!/2`) raises `ArgumentError` naming the entry when:
  - the hooks value is not a list, or an entry is not `{module, keyword}`;
  - `:on_error` is not `:reraise`, `:open` or `:closed`;
  - the opts hold a function, pid, reference or port anywhere (they are saved in a plaintext
    template and must mean the same on another node after a restart);
  - the module is not loaded, exports none of the event callbacks, or exports an event name
    only with the wrong arity;
  - the module's `validate_opts!/1`, when exported, raises (re-raised as
    `"invalid opts for hook Mod: <message>"`).

  It runs at `BaseAgent.init/1`, at `ConfigTemplate.from_config/2` (shape and plain data
  only), at DSL compile time for a literal list (shape and plain data only), and when
  `Turn.Server` loads a session (`Hooks.check_entries/1`, both `:config` and template
  starts): an invalid list there is reported like a store fault, `{:invalid_hooks, message}`,
  so the server waits `:unavailable` and retries instead of failing the start or running
  the session without its hooks.
- **Deploys.** The template freezes the hook list and opts at session creation: a hook added
  to an agent later does not reach existing sessions. A node must have every hook module of
  the sessions it may host; a node without one keeps such a session `:unavailable` (with the
  reason above) until the module is deployed. A node running Normandy without hooks ignores
  `behaviours_refs.hooks`, so ship hooks only after every node runs 2.0.
- Opts must hold no secrets: read them at call time (application env, the credential
  provider). To reach a process, name it (a registered name, `{:via, …}`); to reach a
  per-session resource, derive it from `ctx.session_id` or `ctx.values`.

### 3. Context

`%Normandy.Hooks.Context{event, agent_name, model, session_id, turn_id, values}`, built by
`Context.build(config, event, opts)`:

- `values` is `config.tool_context`;
- `turn_id` is `nil` for `on_session_start`, `on_passivate` and `on_prompt` (the prompt is
  admitted before the turn starts), and for `on_turn_end` after a rejected input or after a
  `BaseAgent` run that raised (the run's config is lost with the exception).

The context carries no config, memory or client: a hook that logs `inspect(ctx)` leaks
nothing the agent was not told to share.

### 4. The Runner

`Normandy.Hooks.Runner` is the only module that calls hook modules. One function per event,
each taking the agent's config (the entries are `config.behaviours.hooks`):
`prompt/2`, `before_llm/2`, `before_tool/2`, `after_tool/3`, `after_compact/3`,
`session_start/1`, `passivate/1`, `turn_end/3`; plus `entries/1`, `hooks?/1` and
`handles?/2`. They are the supported way to test a hook with the library's rules applied.

- **Fast path.** Only entries whose module exports the event's callback run. With none, the
  function returns the pass value at once: no context, no telemetry. Call sites check
  `hooks?/1` first where even the pass value would allocate.
- **Order.** Entries run in list order. A rewrite is what the next entry receives. The first
  halt stops the chain.
- **Function hooks.** For `before_tool`/`after_tool` the module entries run first and the
  existing function lists second (in `Dispatch`). A module halt skips the functions.
- **`:on_error`** (removed from opts before the callback sees them):

  | Event | `:reraise` (default) | `:open` | `:closed` |
  |---|---|---|---|
  | `on_prompt`, `before_llm`, `before_tool` | propagates | logged; the value passes on | halts; reason `"hook Mod crashed: <exception module or kind>"` |
  | `after_tool` | propagates | logged; the result passes on | the result becomes an error result with that reason, so unreviewed output never reaches the model |
  | `after_compact`, `on_session_start` | propagates | logged; injects nothing | propagates |
  | `on_turn_end`, `on_passivate` | logged | logged | logged |

- **Logged-only events.** `on_passivate` and `on_turn_end` run after the outcome is settled.
  A crash is logged and emitted as telemetry; the return value is ignored. Nothing a hook
  does there changes a delivered result or makes a `:transient` supervisor restart a
  passivating session.
- **Return contract.** Checked only where the library consumes the value (§1 table). A
  violation raises `ArgumentError` naming the hook, the callback and the value, whatever
  `:on_error` says (a contract violation is a bug, as with guardrails).
- **Unloaded modules.** A module that is not loaded when its event runs raises
  `ArgumentError` (logged and skipped on the logged-only events). Validation catches this
  earlier on every path that builds a config.
- **Logs.** A rescued crash logs at `:error`: the hook, the event, the exception module and,
  for a `RuntimeError` or `ArgumentError` (author-written text), its message cut to 200
  characters. Exit and throw payloads and other exceptions' messages are not logged: they can
  carry the hook's data (the rule `Turn.Server` follows for handler crashes,
  `server.ex:1143-1149`).
- **Inject collection.** `{:inject, texts}` from every entry is concatenated in list order.
- **No timeouts** (decision 10).

### 5. Events: where they fire and what they do

Line numbers are as of `b241330`.

| Event | Fires at | Effect |
|---|---|---|
| `on_session_start` | `Turn.Server`, as the first event after `init/1` (`{:next_event, :internal, :session_start}`), and inline in a retried load (`retry_load/1`, `server.ex:253`), for a session whose store holds no entries and no turn state | The texts of all entries are joined (blank-line separated) into **one** `"user"` message, appended to memory and stored with one append, so the store holds all of it or none. Not a `BaseAgent` event. |
| `on_passivate` | `server.ex:592`, before `{:stop, :normal, data}`, in `:idle` | None (logged-only). |
| `on_prompt` | `BaseAgent.admit_input!/2` (split out of `admit_turn_input/2`, `base_agent.ex:586`), non-`nil` input, **after** schema validation and **before** input guardrails | The hook receives the validated input. A rewrite is validated again, then guarded and appended. Not run by the standalone `BaseAgent.admit/2,3`. |
| `before_llm` | `Normandy.Hooks.Handlers.wrap/2` around the `call_llm` handler, in `BaseAgent` (`drive_turn`, `base_agent.ex:615`; `run_stream_turn`, `base_agent.ex:964`) and `Turn.Server` (`init_data`, `server.ex:284`), whatever handler set is in use | `{:halt, reason}` ends the turn. Outside the `llm_call` span and the retry loop. In `Turn.Server` it runs in the spawned call task. |
| `before_tool` | `Dispatch.classify/3`, ahead of the function `before_hooks` (`dispatch.ex:219`) | As today: rewrite input (not the call id) or halt; a halt emits `[:normandy, :tool, :denied]` with `:hook_halt`. `execute_approved` (`server.ex:1280`) does not re-run it. |
| `after_tool` | `Dispatch`: every result it returns (executed, budget-denied, and every `classify/3` denial; `dispatch_one/3`'s interim approval denial). `Turn.Server`: results the core builds (approval rejected or expired), in the callback that built them (`server.ex:537`, `server.ex:564`), and interrupted results, after the turn's input was admitted | Rewrite the result; its `tool_call_id` is forced back to the call's. **Every tool result the model sees passes it exactly once.** The function `after_hooks` keep their meaning: they run after the module `after_tool`, on results of tools that ran only. |
| `after_compact` | `Hooks.Handlers.wrap/2` around the `compact` handler, when the compactor's `meta.dropped` is non-empty | `dropped` is the compactor's report (§7); `meta` is passed without `:dropped`. Injected texts are appended to the compacted memory, before the next LLM call (the forced-final call included). |
| `on_turn_end` | `BaseAgent`: after the `[:normandy, :agent, :run]` span closes (`with_agent_run_span`, `base_agent.ex:1681`), on success and on a raise. `Turn.Server`: after the reply, at `:finalize` (`server.ex:997`), `:fail` (`server.ex:1006`), a rejected input, an admission or repair crash, and a failed write of the turn's first messages | None (logged-only). On a raise the original exception is re-raised after the hook. A resumed turn with no caller waiting still fires it. A reply from `:unavailable` (no config loaded) and a stop mid-turn (`terminate/3`) fire none. |

**`Turn.Inline`** has no hook site: it calls only its `deps`. Tool hooks run there when its
`:dispatch` dep dispatches through an agent pipeline (`Dispatch.dispatch_one/3` with
`BaseAgent.base_agent_pipeline/1`), as with any direct `dispatch_one/3` caller; no other event
runs there. **`Turn.Server.terminate/3`** runs no hook (no session-end event).

### 6. Outcomes and halts

`Normandy.HookHaltError{event, hook, reason}` (in `lib/normandy/exceptions.ex`) is the one
halt value. `HookHaltError.outcome/1` is the one mapping both shells use:

| Halt | `BaseAgent` | `Turn.Server` reply | `on_turn_end` sees |
|---|---|---|---|
| `on_prompt` | raises `%HookHaltError{}` | `{:error, {:rejected, %HookHaltError{}}}` | `{:rejected, %HookHaltError{}}` |
| `before_llm` | raises `%HookHaltError{}` | `{:error, {:hook_halted, %HookHaltError{}}}` | `{:error, {:hook_halted, %HookHaltError{}}}` |

An `on_prompt` halt is a rejection: the input never became a turn and nothing is stored, as
with a schema or guardrail rejection, so callers matching `{:error, {:rejected, _}}` handle
it. A `before_llm` halt fails a started turn: the Server's call task rescues the
`HookHaltError` and feeds `{:llm_error, {:hook_halted, e}}` to the core, whose
`{:fail, reason}` produces the reply. After a tool batch, memory is left as an LLM error
leaves it: the tool results are kept and the turn is not completed. A `before_tool` halt is
not a turn halt: it produces the tool result.

Every `on_turn_end` outcome:

| Path | Outcome |
|---|---|
| completed | `{:ok, response}` (`BaseAgent`: the response; `Turn.Server`: the final value) |
| schema or input-guardrail rejection, `on_prompt` halt | `{:rejected, exception}` |
| output-guardrail block | `{:rejected, %Normandy.Guardrails.ViolationError{}}` |
| `before_llm` halt | `{:error, {:hook_halted, %HookHaltError{}}}` |
| any other failure | `BaseAgent`: `{:error, exception}` (or `{:error, {kind, reason}}` for an exit or throw); `Turn.Server`: `{:error, reason}`, the reason replied to the caller |

### 7. Injection and compaction identity

`{:inject, texts}` appends text as `"user"` messages.

- **After compaction** each text is its own message, appended after the compacted memory. The
  history may then hold consecutive user messages; nothing in Normandy or Claudio merges or
  drops them (`claudio_adapter.ex:655-681`), and a test pins that the adapter keeps them all.
- **Session start** joins the texts into one message (§5).
- **Labels and guardrails.** Injected text reaches the model as user text and input
  guardrails do not run on it. The guide recommends wrapping it
  (`<context source="profile">…</context>`) and treating any text from an untrusted source
  as input to vet before injecting.
- **Persistence.** Session-start injections are stored (with the Server's
  `append_to_store`), so they survive a rehydrate. `after_compact` injections are
  **memory-only**, exactly like compaction: the Server never persists compacted memory (the
  `SessionStore` is append-only and a rehydrate rebuilds the uncompacted chain,
  `server.ex:355`).
- **`dropped` and entry ids.** `meta.dropped` is a list of `%AgentMemory.Entry{}` (id,
  parent_id, turn_id, role, original content), oldest first. `Entry` is chosen over a new
  `%{id, message}` shape because it is what memory and `SessionStore.history/2` already hold,
  it carries the id natively, and its content is the original (the compactor's rebuilt
  memory holds a JSON rendering of kept content). Ids are stable because:
  - compaction keeps kept messages under their entry ids (`AgentMemory.add_message/4` gains
    `:id`; `WindowManager` and `Summarizer` re-add kept entries with it), so a message
    dropped by a later compaction of the same memory is reported under the same id;
  - `Turn.Server` writes each message to the store under the id memory gave it, so a
    rehydrated memory (`AgentMemory.from_entries/1`, which keeps store ids,
    `agent_memory.ex:251`) has the ids the live memory had. All five stores honour a given
    id: `InMemory`, `ETS`, `Mnesia`, `Postgres` assign it directly; `SessionStore.Redis`
    already writes it as the entry's `id` field (`redis.ex:211`) and now reads it back
    (falling back to the stream id for entries written without one), and `fork/3` accepts
    either id (decided by Q, 2026-10-03).
- **At least once.** After a rehydrate the uncompacted chain is back, compaction runs again
  and `after_compact` fires again for the same messages, under the same ids. Hooks
  deduplicate on entry id (the guide's example writes with `put(…, :new)`, which conflicts on
  a second write). An earlier injection that a later compaction drops is reported like any
  other user message.

### 8. `Turn.Server` robustness

Invariant: **no hook outcome terminates `Turn.Server`.** Hook calls made in the server
process go through the existing `call_handler/3` discipline (`server.ex:1112-1128`):

- `on_prompt` runs inside admission. Rejections (schema, guardrail, `on_prompt` halt) reply
  `{:error, {:rejected, e}}`; any other raise, exit or throw from admission (a hook or input
  guardrail crashing under `:reraise`, a hook's contract violation) replies
  `{:error, {:handler_crashed, :admit, e}}` and the server stays `:idle`.
- `on_session_start` runs after `init/1` returns, so a slow hook does not block the
  supervisor that starts the session. A crash replies nothing (no caller); the server goes
  `:unavailable` with `{:handler_crashed, :on_session_start, e}` and retries with the store
  backoff (200 ms doubling to 30 s), running the hook on each retry and on each `run/2`,
  which gets that reason until a start succeeds. A store fault writing the injection does
  the same with `{:persist_failed, reason}`. Under `:open` a crash is logged and the session
  starts without injection.
- `after_tool` on core-built and interrupted results: a crash fails the turn (or the
  request) with `{:handler_crashed, :after_tool, e}`; the batch's tool_use is then repaired
  with interrupted results on the next turn.
- `on_turn_end` and `on_passivate`: logged-only; the reply is sent first.

`on_session_start` fires on every start of a session whose store is empty: a hook that injects
nothing, a session that passivated before its first turn, or one whose turns were all
rejected, fires again on its next start. Side-effecting session-start hooks must be
idempotent.

Interrupted results are built and passed through `after_tool` only after the turn's input is
admitted, so a rejected input does not report them; admission now runs before the repair
(`server.ex:464-468` today runs it after). A repair whose store write fails is reported again
by the next turn that repairs it.

### 9. Telemetry

A span per entry call: `[:normandy, :hook, :start | :stop | :exception]`.

- Metadata: `event`, `hook` (the module), `agent_name`, `session_id`, `turn_id`; tool events
  add `tool_call_id` and `tool`.
- `:stop` adds `result`: `:cont | :rewrite | :halt | :inject | :ok | :rescued` (`:rescued` is
  an `:open`/`:closed` or logged-only crash).
- `:exception` fires when a crash propagates (`:reraise`, or `:closed` on `after_compact`/
  `on_session_start`) or a return value breaks its contract.
- Documented in the `Normandy.Telemetry` moduledoc; `test/telemetry/catalogue_test.exs`
  enforces it.

### Public contract changes

- New: `Behaviours.Config.hooks`, `behaviours_refs.hooks` in templates,
  `Normandy.Behaviours.Hooks` (with `use`), `Normandy.Hooks.Context`, `Normandy.Hooks.Runner`,
  `Normandy.Hooks.Handlers`, `Normandy.HookHaltError`; DSL `hooks`.
- `Turn.Server.run/2` may reply `{:error, {:rejected, %HookHaltError{}}}`,
  `{:error, {:hook_halted, %HookHaltError{}}}`, `{:error, {:handler_crashed, :admit | :after_tool | :on_session_start, e}}`
  and `{:error, {:invalid_hooks, message}}`.
- **Behaviour change:** `Turn.Server` admission that raises something other than a rejection
  (a crashing input guardrail, for example) now replies `{:handler_crashed, :admit, e}`
  instead of crashing the session.
- **Behaviour change:** `Turn.Server` admits a turn's input before repairing an interrupted
  batch (it repaired first).
- **Behaviour change:** compaction keeps kept messages' entry ids, and `Turn.Server` stores
  each message under its memory entry id.
- `Compactor` meta may carry `:dropped`; `Compactor.WindowManager` fills it.
- `AgentMemory.add_message/4` accepts `:id`.
- `Dispatch.Pipeline` gains `after_tool` (default `nil`); `Dispatch` applies it to every
  result it returns.
- Unchanged: the function `before_hooks`/`after_hooks` (no behaviour change).

## Testing

- **Runner unit tests:** list order; rewrite threading; a halt stops the chain; string and
  `%ToolResult{}` `before_tool` halts; each `:on_error` mode for raise, exit and throw per
  the §4 table; logged-only events never raise and ignore returns; `:on_error` stripped from
  opts; contract violations raise; `{:inject, []}`; inject concatenation; entries without
  the callback skipped; unloaded modules; telemetry spans and `result` values.
- **Behaviour and validation:** each `ArgumentError` case in §2; `use` compile-time checks;
  `@optional_callbacks`/`events/0` drift; plain-data rule with pid, function and reference.
- **Compaction contract:** `WindowManager` (`:oldest_first`, `:summarize`) and `Summarizer`
  keep kept entry ids; `Compactor.WindowManager` reports exactly the removed entries.
- **Wiring, per event and per path:** `BaseAgent.run`, streaming, `Turn.Server` with default
  and custom handlers. Includes: `on_prompt` sees the validated input; a plain-map rewrite the
  schema rejects raises `ValidationError`; a schema-struct rewrite is trusted; `before_llm`
  halts; module `before_tool` halt skips the function hooks; `after_tool` sees denials once;
  `after_compact` receives the compactor's `dropped` and does not fire on an empty one;
  `on_turn_end` outcomes, ordering (after the span; after the reply).
- **`Turn.Server` robustness:** each §8 path keeps the server alive and replies as stated;
  `start_link` returns before `on_session_start` runs; passivation stops `:normal` with a
  crashing `on_passivate`.
- **Core-built and interrupted results:** rejected, expired (`:fail`), mixed approval and
  interrupted results pass `after_tool` exactly once; a rejected input followed by an
  accepted one reports an interrupted result once; function `after_hooks` do not see them.
- **Persistence:** hooks survive a `ConfigTemplate` round trip and a template (thin) start;
  a template without `hooks` rebuilds with `[]`; a missing hook module keeps the server
  `:unavailable`; store entries carry memory's ids; session-start injections survive a
  rehydrate; `after_compact` injections are not written to the store.
- **Adapter:** consecutive user messages from `AgentMemory.history/1` are neither merged nor
  dropped.
- **Docs:** the guide's example modules compile without warnings; its event table names every
  event.
- No live e2e scenario: everything is covered offline, and only Q runs `mix e2e`.

## Docs

- `docs/guides/hooks.md` (added to `mix.exs` docs extras): purposes; declaring hooks; module
  vs function hooks; events; outcomes; `:on_error`; injection; compaction identity and
  deduplication; reaching runtime resources (no pids, no secrets); testing a hook; what hooks
  do not cover; telemetry. One worked example per purpose: redaction in `on_prompt`, inject
  on session start, save dropped entries in `after_compact` (into a memory store, idempotent
  by entry id), an audit module on `on_turn_end` and `after_tool`.
- `MIGRATING-2.0.md`: a section for the new replies and the behaviour changes above.
- `CLAUDE.md`: Architecture entry for hooks.
- DSL moduledoc (the `hooks` declaration), `Turn.Inline` moduledoc (the §5 statement),
  `Turn.Server` moduledoc (new replies, session start), `Compactor` moduledoc (`:dropped`).

## Out of scope

- A reliable session-end event (needs `trap_exit` in `Turn.Server`; "end" is undefined across
  Horde handoff and `ResumeReaper`).
- LLM request/response rewriting (tool-call pairing, thinking-block replay, streamed chunks).
- `before_compact`, and a Compactor callback that previews what it will drop.
- Hooks in the standalone pre-charge `BaseAgent.admit/2,3`.
- Hook timeouts (decision 10).
- Exactly-once `on_session_start` (a durable "started" marker) and two first starts of one
  session racing under Horde (both see an empty store); both need a store-level marker.
- Marking injected entries so `after_compact` leaves them out; a compaction watermark.
- `on_turn_end`'s `turn_id` for a `BaseAgent` run that raised (needs a wrapping exception or
  process state).
- Running `before_tool` concurrently in `Turn.Server` (it classifies a batch serially, as it
  does for the function hooks today); raise `max_tool_concurrency` for slow `after_tool`.
- Rate-limited crash logs, per-entry `telemetry: false`, crash details in telemetry metadata.
- Accepting a bare `Mod` entry, replacing DSL-declared hooks at `new/1`, structured
  injections (`{:context, text}`).
