# Turn.Server failures, events and approval expiry — design

Date: 2026-09-30. Branch: `feat/claudio-0.7-migration` (Normandy 2.0).
Source: `investigations/codebase-audit-2026-09/` — AGENTS-1, plus known item A3 (dangling
`tool_use` across a crash), plus findings made while designing (§2, §3).

## Problem

`Turn.Server` (the `:gen_statem` turn shell) mishandles failure and under-reports what happens.

- **Rejected input crashes the session.** `handle_event({:call, from}, {:turn, input}, :idle, _)`
  calls `BaseAgent.admit_turn_input/2` (`server.ex:180`), which raises
  `Normandy.Schema.ValidationError` on schema failure and `Normandy.Guardrails.ViolationError`
  on an input-guardrail block. The statem crashes, the caller gets an exit, the `:transient`
  child restarts, and four such crashes in 5 s (any sessions) terminate `Turn.Supervisor`.
- **Synchronous callbacks crash the session.** The interpreter runs `handlers.append`,
  `convert`, `validate`, `guard` and the subscriber inside the server process
  (`server.ex:285-312`, `:392`). Any raise or exit crashes it the same way.
- **The Server never calls `handlers.emit`.** `Turn.Driver` does (`driver.ex:52`); the Server
  calls only the subscriber, so BaseAgent's `emit_turn_event/3` debug log is lost.
- **The forced final LLM call is unannounced.** When the iteration budget is spent the core
  makes one more call with no `:iteration` event (`turn.ex:163-168`).
- **`:steering` is announced before its state is persisted** (`turn.ex:309`), unlike
  `:awaiting_approval`, which persists first on purpose (`turn.ex:189`).
- **A resumed parked turn is never re-announced.** `Turn.resume/1` returns `{s, []}` for
  `:awaiting_approval` (`turn.ex:279`); the timeout re-arms and nobody is told.
- **Approval expiry is reported as a rejection.** On `:approval_expiry` the server steps
  `{:approval, %{}}` (`server.ex:255`). Every parked call gets "tool call rejected by approver",
  the turn continues, and the caller gets `{:ok, _}`. No event, telemetry or log records the
  expiry, and repeated parks each wait the full timeout.
- **A failed or killed turn can leave an unanswered `tool_use`.** The assistant message with
  `tool_calls` is appended before dispatch (`turn.ex:136`). If the turn stops before the results
  are appended (dispatch task crash, store/handler failure mid-batch, server killed, or resume
  finding `:tool_dispatch` → `{:unresumable_state, _}`), memory and store end with a `tool_use`
  that has no `tool_result`. The next turn's request is rejected by the Claude API (400).

## Decisions (approved by Q)

1. Rejected input replies `{:error, {:rejected, exception}}`.
2. A raising subscriber is logged (plus telemetry) and ignored; the turn continues.
3. Approval expiry: honest expiry results and events (a), and an `on_approval_timeout:
   :continue | :fail` option (b). Approach A: a new pure core event.
4. Fold in: `handlers.emit` parity, final-iteration event, persist-before-steering, resume
   re-announce, and repair of dangling `tool_use` batches.
5. Out of scope, recorded in the audit: AGENTS-16 (ResumeReaper drops server options) and
   OTP-16 (`Turn.Supervisor` restart intensity).

## Design

### 1. Failure replies (AGENTS-1) — `lib/normandy/agents/turn/server.ex`

**Rejected input.** In the `{:turn, input}` clause, `admit_turn_input/2` runs inside
`try`, rescuing **only** `Normandy.Schema.ValidationError` and
`Normandy.Guardrails.ViolationError`:

```elixir
{:keep_state, data, [{:reply, from, {:error, {:rejected, exception}}}]}
```

Nothing is persisted; `data` (config, memory, turn state) is unchanged. Any other exception
propagates (a bug, not an outcome).

**Crashing synchronous handler.** Each call to `handlers.append`, `convert`, `validate`,
`guard` and `emit` runs inside `try ... catch kind, reason`. On a catch:

```elixir
exception = Exception.normalize(kind, reason, __STACKTRACE__)
fail(data, {:handler_crashed, handler_name, exception})
```

`handler_name` is one of `:append | :convert | :validate | :guard | :emit`. For `:exit` and
`:throw`, `Exception.normalize/3` returns the raw term unchanged (only `:error` is normalised),
so the third element is an exception for raises and the exit/throw value otherwise; the spec
types it `Exception.t() | term()`. `fail/2` is the existing shell bypass (`server.ex:384`):
marks the turn `:failed`, persists it, replies `{:error, reason}`, returns to `:idle`.

A `Logger.error` records the handler name, `kind`, and `Exception.format(kind, reason,
stacktrace)`. Never the config, `client.options`, or `req_options`.

### 2. Events

**2a. Emit order (`server.ex` `emit/3`).** For `{:emit_event, name, meta}`:
1. `data.handlers.emit.(data.config, name, meta)` — a crash is a handler crash (§1,
   `:emit`). `%Driver.Handlers{}` defaults `emit` to `nil`; the Server skips a `nil` emit
   (a hand-built handler set without one keeps working). The default
   `BaseAgent.non_streaming_handlers/0` sets it.
2. The subscriber, if set — inside `try ... catch kind, reason`. On a catch:
   `Logger.error("Turn.Server subscriber crashed", session_id:, event: name, kind:,
   message: ...)` (message from `Exception.normalize/3` + `Exception.message/1` when it is an
   exception, otherwise `inspect` of the exit/throw term; never `meta`) and

   ```elixir
   :telemetry.execute([:normandy, :turn, :subscriber, :exception], %{count: 1},
                      %{session_id: sid, event: name, kind: kind})
   ```

   The turn continues.

**2b. Final iteration (`turn.ex`).** Every `:iteration` event's meta gains `final:
boolean()`. The forced-final clause (`turn.ex:163`, `left <= 0`) now emits, before its
`{:call_llm, ...}`:

```elixir
{:emit_event, :iteration,
 %{iteration: s.max_iterations - s.iterations_left + 1, iterations_left: s.iterations_left,
   final: true}}
```

The two existing `:iteration` emits add `final: false`. All three shells handle `:emit_event`
already; no interpreter change.

**2c. Persist before announcing (`turn.ex` `apply_tool_results/2`).** Effect order becomes
`append_effects ++ [{:persist, s2}, steering, {:maybe_compact, ...}]`.

**2d. Resume re-announces (`turn.ex:279`).**

```elixir
def resume(%State{status: :awaiting_approval, parked_calls: parked} = s),
  do: {s, [{:emit_event, :awaiting_approval, %{parked: length(parked), resumed: true}}]}
```

The live park (`turn.ex:194`) adds `resumed: false`. The Server's `interpret([], ...)` for
`:awaiting_approval` already re-arms the timeout after the effects run.

### 3. Approval expiry (approach A)

**Option.** `Turn.Server.start_link/1` accepts `on_approval_timeout: :continue | :fail`,
default `:continue`, stored in `%Data{}`. Validated in `start_link/1` before the statem
starts:

```elixir
raise ArgumentError,
  "Turn.Server.start_link/1: invalid :on_approval_timeout, expected :continue or :fail, " <>
  "got: #{inspect(value)}"
```

`Turn.Session` (both `Keyword.take` lists, `session.ex:103-111`, `:117-125`) and
`Coordination.AgentProcess` (`extra_session_opts`, `agent_process.ex:274-279`) forward it.

**Shell (`server.ex:254`).** On `:state_timeout, :approval_expiry`:

```elixir
:telemetry.execute([:normandy, :turn, :approval, :expired],
                   %{count: length(parked)},
                   %{session_id: sid, mode: mode, timeout_ms: ms, tool_names: names})
Turn.step(data.turn_state, {:approval_expired, %{mode: mode, timeout_ms: ms}})
```

`tool_names` are the parked calls' names. No inputs.

**Core (`turn.ex`).** New clauses:

- `{:approval_expired, _}` with `status: :awaiting_approval, parked_calls: []` →
  `{:unexpected_event, :awaiting_approval, :approval_expired_without_parked_calls}` failure,
  mirroring `turn.ex:203`.
- With parked calls, each gets:

  ```elixir
  %ToolResult{tool_call_id: id, is_error: true,
    output: %{error: "approval timed out: no approver responded within #{ms}ms",
              denied: true, expired: true, pending_approval: false}}
  ```

  `results = reorder(held ++ expired, s.pending_calls)`;
  `event = {:emit_event, :approval_expired, %{expired: length(parked), mode: mode}}`.

- `mode: :continue` → `{s2, effects} = apply_tool_results(s, results)`; return
  `{s2, [event | effects]}`. The turn continues; the model sees the truth.
- `mode: :fail` → `reason = {:approval_timeout, Enum.map(parked, & &1.id)}`;
  state `%{s | status: :failed, error: reason, pending_calls: [], parked_calls: [],
  held_results: []}`; effects
  `Enum.map(results, &{:append_message, "tool", &1}) ++ [event, {:fail, reason}]`.
  The batch is complete in memory and store before failing; the Server's `{:fail, _}` clause
  persists the terminal state and replies `{:error, {:approval_timeout, ids}}`.

Unchanged: an approver who answers via `approve/2` but leaves calls undecided rejects them
("tool call rejected by approver"). Expiry means no decision arrived.

`Turn.Driver` and `Turn.Inline` never park, so they never receive `{:approval_expired, _}`.
They gain no clause (consistent with their missing `:execute_approved` clause, AGENTS-15).

### 4. Dangling `tool_use` repair (A3)

**Detection (pure, `turn.ex`).**

```elixir
@spec unanswered_tool_calls([Message.t()]) :: [ToolCall.t()]
```

Finds the last `"assistant"` message. If its content has non-empty `:tool_calls`, returns
those calls whose id has no `%ToolResult{tool_call_id: id}` in a later `"tool"` message, in
`tool_use` order. Otherwise `[]`.

**Repair (Server `{:turn, input}` clause).**
1. `missing = Turn.unanswered_tool_calls(AgentMemory.messages(data.config.memory))`.
2. `interrupted = Enum.map(missing, &interrupted_result/1)`:

   ```elixir
   %ToolResult{tool_call_id: id, is_error: true,
     output: %{error: "tool call interrupted: the previous turn ended before a result was " <>
                      "recorded; the tool may or may not have run",
               interrupted: true}}
   ```

3. Fold `interrupted` into memory with `handlers.append` (role `"tool"`), then run
   `admit_turn_input/2` on the repaired config.
   A crash in `handlers.append` here (no turn exists yet, so `fail/2` does not apply) replies
   `{:error, {:handler_crashed, :append, exception_or_term}}` with `data` unchanged and
   nothing persisted.
4. Rejected input (§1) → discard both; reply `{:error, {:rejected, e}}`; nothing changes.
5. Accepted → write each interrupted result to the store (`append_to_store/3`), then the user
   message (`persist_user_message/3`). Memory and store keep the same order. A store failure
   here replies `{:error, {:persist_failed, reason}}` as today.
6. When `missing != []`: `Logger.warning` with session id, count and tool names (no inputs).

Consecutive user-role messages are already normal (the adapter sends each `"tool"` message as
its own `:user` message, `claudio_adapter.ex:651`, `:661`), so results followed by the new
user message add no API risk.

`Turn.Driver` gets no repair: it raises and the caller keeps its pre-turn config.

### Public contract changes (`Turn.Server.run/2`, all within `{:error, term()}`)

| Reason | When |
|---|---|
| `{:rejected, exception}` | input failed schema or input guardrail; nothing changed |
| `{:handler_crashed, name, exception_or_term}` | a synchronous handler raised/exited/threw |
| `{:approval_timeout, [tool_call_id]}` | `on_approval_timeout: :fail` and nobody approved |

Event meta additions: `:iteration` `final`, `:awaiting_approval` `resumed`, new
`:approval_expired` event. New telemetry: `[:normandy, :turn, :subscriber, :exception]`,
`[:normandy, :turn, :approval, :expired]`. New option: `on_approval_timeout`. Tool result
output gains `expired: true` (expiry) and `interrupted: true` (repair).

## Testing

Core (`test/agents/turn_test.exs`; expiry cases in `test/agents/turn_approval_test.exs`), pure, no processes:
- forced-final clause emits `:iteration` with `final: true` before `:call_llm`; others
  `final: false`.
- `apply_tool_results` effect order: appends, `:persist`, `:steering`, `:maybe_compact`.
- `resume/1` on `:awaiting_approval` emits `:awaiting_approval` with `resumed: true`.
- `{:approval_expired, %{mode: :continue}}`: expired results (exact output map), reordered with
  held results, `:approval_expired` event first, then the steering sequence.
- `{:approval_expired, %{mode: :fail}}`: status `:failed`, error
  `{:approval_timeout, ids}`, appends cover every `pending_calls` id, then event, then `:fail`.
- `{:approval_expired, _}` with `parked_calls: []` → `:unexpected_event` failure.
- `unanswered_tool_calls/1`: none, all, some answered; last assistant without tool calls;
  results present for an earlier assistant only.

Server (`test/agents/turn/server_test.exs`):
- schema-invalid input → `{:error, {:rejected, %ValidationError{}}}`; same pid alive; store
  history unchanged; next valid turn `{:ok, _}`.
- input guardrail block → `{:rejected, %ViolationError{}}`.
- cascade: under a real `Turn.Supervisor`, 5 rejected inputs → server and supervisor alive.
- raising custom `validate` → `{:error, {:handler_crashed, :validate, %RuntimeError{}}}`;
  persisted turn state `:failed`; server alive.
- exiting custom `append` → `{:handler_crashed, :append, _}`.
- custom `handlers.emit` is called in the Server shell.
- raising subscriber → turn `{:ok, _}`; `[:normandy, :turn, :subscriber, :exception]` fired.
- expiry `:continue` (default) → `{:ok, _}`; LLM's second request contains the expired
  output; `:approval_expired` subscriber event; expiry telemetry with `tool_names`.
- expiry `:fail` → `{:error, {:approval_timeout, [id]}}`; store history has a `tool_result`
  for every `tool_use`; persisted state `:failed`.
- invalid `on_approval_timeout` → `ArgumentError` naming the key and value.
- resume of a persisted parked turn → subscriber receives `:awaiting_approval` with
  `resumed: true`.
- dangling repair: seed a store/memory ending in an assistant `tool_use` with no result;
  next turn `{:ok, _}`; the LLM request carries the interrupted result before the user
  message; store order matches; a rejected input in the same state leaves the store
  untouched.

Session/AgentProcess: `on_approval_timeout` reaches the server (one test each, or one through
`Turn.Session`).

## Docs

- `Turn.Server` moduledoc: options (`:subscriber`, `:approval_timeout_ms`,
  `:on_approval_timeout`), the three events and their meta, the error reasons table, the
  subscriber-crash rule, and dangling repair.
- `MIGRATING-2.0.md`: new section "12. `Turn.Server` failure replies and approval expiry"
  covering the reply reasons, approval-expiry wording, the new option, and event meta
  additions.
- `CLAUDE.md`: one line under Agent System for `on_approval_timeout` and `{:rejected, _}`.
- Never edit `@version` or `CHANGELOG.md` (cocogitto owns them).

## Out of scope

- AGENTS-16: ResumeReaper restarts sessions without their server options (subscriber,
  handlers, timeouts, `on_approval_timeout`). Fix with AGENTS-2.
- OTP-16: `Turn.Supervisor` default restart intensity.
- Validating Server options other than `on_approval_timeout`.
- Approval for `Turn.Driver` / `Turn.Inline` (they do not park).
