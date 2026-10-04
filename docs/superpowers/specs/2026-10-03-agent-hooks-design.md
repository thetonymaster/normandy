# Agent lifecycle hooks — design

Date: 2026-10-03. Branch: `feat/claudio-0.7-migration` (Normandy 2.0).
Source: brainstorm with Q, 2026-10-03.

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

There is also an audit gap in today's tool hooks: results `Turn.Server` synthesizes itself —
approval rejected (`server.ex:545`), approval expired (`server.ex:580`), interrupted-batch
repair (`server.ex:869`) — never pass through `after_hooks`.

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
   no hooks.
7. Events: `on_session_start`, `on_passivate`, `on_prompt`, `before_llm`, `before_tool`,
   `after_tool`, `after_compact`, `on_turn_end`.
8. Out: a reliable `session_end` (needs `trap_exit` in `Turn.Server`), LLM request/response
   rewriting, and `before_compact` (it cannot know whether compaction will happen;
   `after_compact` receives the dropped messages instead).

## Design

### 1. The behaviour

```elixir
defmodule Normandy.Behaviours.Hooks do
  @type opts :: keyword()
  @type outcome :: {:ok, response :: term()} | {:error, reason :: term()} | {:rejected, Exception.t()}

  @callback on_session_start(Context.t(), opts) :: :ok | {:inject, [String.t()]}
  @callback on_passivate(Context.t(), opts) :: :ok
  @callback on_prompt(input :: term(), Context.t(), opts) ::
              {:cont, term()} | {:halt, reason :: String.t()}
  @callback before_llm(%{final: boolean(), iterations_left: integer()}, Context.t(), opts) ::
              :cont | {:halt, reason :: String.t()}
  @callback before_tool(ToolCall.t(), Context.t(), opts) ::
              {:cont, ToolCall.t()} | {:halt, ToolResult.t()}
  @callback after_tool(ToolCall.t(), ToolResult.t(), Context.t(), opts) :: {:cont, ToolResult.t()}
  @callback after_compact(dropped :: [Message.t()], meta :: map(), Context.t(), opts) ::
              :ok | {:inject, [String.t()]}
  @callback on_turn_end(outcome(), Context.t(), opts) :: :ok
  @callback validate_opts!(opts) :: :ok

  @optional_callbacks on_session_start: 2, on_passivate: 2, on_prompt: 3, before_llm: 3,
                      before_tool: 3, after_tool: 4, after_compact: 4, on_turn_end: 3,
                      validate_opts!: 1
end
```

Every callback is optional. The Runner skips an entry whose module does not export the
event's callback.

### 2. Configuration and persistence

- `Behaviours.Config` gains `hooks: [{module(), keyword()}]`, default `[]`.
- `ConfigTemplate.from_config/2` records it in `behaviours_refs.hooks`; `rebuild/3` restores
  it. A template saved before the field existed rebuilds with `[]`. Opts must be plain data;
  `from_config/2` already raises on a function or pid.
- `Normandy.DSL.Agent` gains a `hooks [{Mod, opts}, …]` declaration.
- **Validation** at `BaseAgent.init/1` (and at compile time in the DSL where the entry is a
  literal) raises `ArgumentError` naming the entry when:
  - an entry is not `{module, keyword}`;
  - the module is not loaded or exports none of the event callbacks;
  - `:on_error` is not `:reraise`, `:open` or `:closed`;
  - the module's `validate_opts!/1`, when exported, raises.

### 3. Context

`%Normandy.Hooks.Context{agent_name, session_id, turn_id, values, config}`, built like
`Normandy.Tools.Context.build/2`:

- `values` is `config.tool_context`;
- `config` is the agent's `%BaseAgentConfig{}`, read-only — no return value can change it;
- `turn_id` is `nil` for `on_session_start`, `on_passivate` and `on_prompt` (the prompt is
  admitted before the turn starts).

### 4. The Runner

`Normandy.Hooks.Runner` is the only module that calls hook modules. Each call site makes one
`Runner.run(event, args, ctx, config)` call. The Runner owns:

- **Order.** Entries run in list order. A rewrite (`{:cont, new}`) is what the next entry
  receives. The first `:halt` stops the chain.
- **Function hooks.** For `before_tool`/`after_tool`, the module entries run first and the
  existing function lists second (in `Dispatch`). A module halt skips the functions.
- **`:on_error`.** Stripped from opts before the callback sees them.
  - `:reraise` (default): the exception, exit or throw propagates.
  - `:open`: logged; the entry counts as passing (`:cont` with the value unchanged, or `:ok`).
  - `:closed`: on a haltable event (`on_prompt`, `before_llm`, `before_tool`) the entry halts
    with a reason naming the hook and the exception module; on other events it behaves as
    `:reraise`.
- **Logged-only events.** `on_passivate` and `on_turn_end` run after the outcome is settled.
  A crash there is always logged and emitted as telemetry, never re-raised, whatever
  `:on_error` says. Re-raising would turn a delivered success into an error, and a crash
  during passivation would make a `:transient` supervisor restart the session it is stopping.
- **Return contract.** A return value outside the callback's spec raises `ArgumentError`
  naming the hook and the value, regardless of `:on_error` (a contract violation is a bug,
  as with guardrails).
- **Inject collection.** `{:inject, texts}` from every entry is concatenated in list order.

### 5. Events: where they fire and what they do

Line numbers are as of `b241330`.

| Event | Fires at | Effect |
|---|---|---|
| `on_session_start` | `Turn.Server` `init_data` (`server.ex:284`), **fresh sessions only**: the store held no entries for the `session_id` | Injected texts are appended and persisted to the session store. A rehydrated or resumed session does not fire it; otherwise every restart or node handoff would inject again. |
| `on_passivate` | `server.ex:592`, before `{:stop, :normal, data}` | None (logged-only). |
| `on_prompt` | Start of `BaseAgent.admit_turn_input/2` (`base_agent.ex:584`), non-`nil` input, **before** schema validation and input guardrails | The rewritten input is what is validated, guarded and appended. Not run by the standalone `BaseAgent.admit/2,3`. |
| `before_llm` | `call_turn_llm` (`base_agent.ex:653`) and `call_stream_llm` (`base_agent.ex:1014`), before the `llm_call` span | `{:halt, reason}` ends the turn. In `Turn.Server` this runs inside the spawned call task. |
| `before_tool` | `Dispatch.classify/3`, before the existing `run_before_hooks` (`dispatch.ex:219`) | As today: rewrite input (not the call id) or halt with a `%ToolResult{}`; a halt emits `[:normandy, :tool, :denied]` with `:hook_halt`. `execute_approved` (`server.ex:1280`) does not re-run it; it ran at classify. |
| `after_tool` | `Dispatch.execute/4`, before the existing `run_after_hooks` (`dispatch.ex:264`); **and** on every result `Turn.Server` synthesizes (`server.ex:545`, `580`, `869`) | Rewrite the result. The synthesized results also pass through the existing `after_hooks` functions (a behavior change; see Public contract changes). The result's `tool_call_id` is forced back to the call's id, as today. |
| `after_compact` | `BaseAgent.compact_turn_memory/3` (`base_agent.ex:800`), only when `meta.compacted` is true | `dropped` is the messages in memory before compaction that are not in memory after it, in their original order. Injected texts are appended to the compacted memory. |
| `on_turn_end` | `BaseAgent`: `with_agent_run_span` (`base_agent.ex:1681`), success and exception paths. `Turn.Server`: `:finalize` (`server.ex:997`), `:fail` (`server.ex:1007`), `emit_rejected_run` (`server.ex:720`) | None (logged-only). On the exception path the original exception is re-raised after the hook. |

Not covered: `Turn.Inline` (its effects run through caller-supplied functions; its moduledoc
says hooks do not run there), and `Turn.Server.terminate/3` (no session-end event).

### 6. Halts

- `BaseAgent` raises `%Normandy.HookHaltError{event, hook, reason}` (in
  `lib/normandy/exceptions.ex`).
- `Turn.Server` replies `{:error, {:hook_halted, event, reason}}` and returns to `:idle`, and
  ends the run span with `:exception`.
- A `before_llm` halt after a tool batch leaves memory as an LLM error would today: the tool
  results are kept and the turn is not completed.
- A `before_tool` halt is not a turn halt: it produces the tool result, as today.
- `on_turn_end` sees an `on_prompt` halt as `{:rejected, %HookHaltError{}}` (the input never
  became a turn, like a guardrail rejection) and a `before_llm` halt as
  `{:error, {:hook_halted, :before_llm, reason}}`.
- `on_session_start` cannot halt. A crash there under `:reraise` (or `:closed`) fails
  `Turn.Server.init/1`, so the session does not start and the caller of
  `Session.rehydrate_and_start` gets the error; under `:open` it is logged and the session
  starts without injection.

### 7. Injection

`{:inject, texts}` appends each text as a `"user"` message to memory, in order.

- **After compaction** the injected message follows a tool-results message, so the history
  has two user messages in a row. The Anthropic API combines consecutive same-role turns, but
  the Claudio adapter's conversion has not been checked. A test sends such a history through
  the adapter's message conversion and asserts a valid request. If it fails, injected text
  is merged into the preceding user message instead, and this spec is updated.
- **Persistence.** In `Turn.Server`, injected messages are persisted the same way the
  compacted memory (`after_compact`) or session entries (`on_session_start`) are. The plan
  verifies how the Server persists compacted memory before wiring this.
- `on_prompt` cannot inject: it rewrites the input instead.

### 8. Telemetry

A span per entry call: `[:normandy, :hook, :start | :stop | :exception]`.

- Metadata: `event`, `hook` (the module), `agent_name`, `session_id`, `turn_id`.
- `:stop` adds `result`: `:cont | :rewrite | :halt | :inject | :ok | :rescued` (`:rescued` is
  an `:open`/`:closed` or logged-only crash).
- Documented in the `Normandy.Telemetry` moduledoc; `test/telemetry/catalogue_test.exs`
  enforces it.

### Public contract changes

- `Behaviours.Config.hooks` (new field) and `behaviours_refs.hooks` in the config template.
- `Normandy.Behaviours.Hooks`, `Normandy.Hooks.Context`, `Normandy.Hooks.Runner`,
  `Normandy.HookHaltError` (new).
- `Turn.Server` may reply `{:error, {:hook_halted, event, reason}}` (new).
- **Behavior change:** the existing `after_hooks` functions now also run on results
  `Turn.Server` synthesizes (approval rejected or expired, interrupted-batch repair).
- DSL: `hooks` declaration.

## Testing

- **Runner unit tests:** list order; rewrite threading; a halt stops the chain; each
  `:on_error` mode for raise, exit and throw; `:closed` on a non-haltable event re-raises;
  logged-only events never re-raise; `:on_error` stripped from opts; bad return value raises;
  inject concatenation; entries without the callback skipped.
- **Validation:** each `ArgumentError` case in §2, at `BaseAgent.init/1` and in the DSL.
- **Wiring, per event and per path that has it:** `BaseAgent.run`, streaming, `Turn.Server`,
  using the existing scripted clients. Includes: `on_prompt` rewrite is validated and guarded;
  `before_llm` halt raises / replies `{:hook_halted, …}`; module `before_tool` halt skips the
  function hooks; `after_compact` receives exactly the dropped messages and does not fire when
  `compacted: false`; `on_turn_end` sees `{:ok, _}`, `{:error, _}` and `{:rejected, _}`.
- **Server-synthesized results** pass through `after_tool` and the function `after_hooks`.
- **Persistence:** hooks survive a `ConfigTemplate` round trip and a Server rehydrate; a
  template without `hooks` rebuilds with `[]`; `on_session_start` fires for a fresh session
  and not after rehydrate; injected messages survive a rehydrate.
- **Injection request shape:** the consecutive-user-message test in §7.
- **Telemetry:** span events and `result` values; catalogue test passes.
- No live e2e scenario: everything is covered offline, and only Q runs `mix e2e`.

## Docs

- `docs/guides/hooks.md` (added to `mix.exs` docs extras), with one worked example per
  purpose: redaction in `on_prompt`, inject on session start, save dropped messages in
  `after_compact` (e.g. into the memory store), an audit module on `on_turn_end` and
  `after_tool`. States what Inline does not run and why there is no session-end event.
- `MIGRATING-2.0.md`: new section for the `after_hooks` behavior change, `HookHaltError` and
  the `{:hook_halted, …}` reply.
- `CLAUDE.md`: Architecture entry for hooks.
- DSL moduledoc: the `hooks` declaration.

## Out of scope

- A reliable session-end event (needs `trap_exit` in `Turn.Server`; "end" is undefined across
  Horde handoff and `ResumeReaper`).
- LLM request/response rewriting (tool-call pairing, thinking-block replay, streamed chunks).
- `before_compact`, and a Compactor callback that previews what it will drop.
- Hooks in `Turn.Inline`.
- Hooks in the standalone pre-charge `BaseAgent.admit/2,3`.
