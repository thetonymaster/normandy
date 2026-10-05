# Lifecycle hooks

## What hooks are for

A hook is a module an agent lists in `Normandy.Behaviours.Config` `:hooks`. Normandy calls
it at eight points of an agent's life. Use a hook to:

- **guard or rewrite** — redact a prompt, block an off-topic request, stop an LLM call
  over budget, rewrite a tool call or its result;
- **inject context** — add a user profile when a session starts, or a reminder after
  compaction;
- **save what compaction drops** — copy dropped messages to long-term memory;
- **audit** — record tool results and turn outcomes.

To only observe, attach to telemetry (`Normandy.Telemetry`) instead: a hook runs inline,
in the turn, with no timeout. A slow hook stalls its turn (in `Turn.Server`, its session):
hand slow side effects to a process of your own.

## Declaring hooks

```elixir
alias Normandy.Behaviours.Config

BaseAgent.init(%{
  client: client,
  model: "claude-sonnet-4-5",
  behaviours: %Config{hooks: [{MyApp.Hooks.Redact, []}, {MyApp.Hooks.Audit, on_error: :open}]}
})
```

or, in the DSL, once per agent:

```elixir
agent do
  model("claude-sonnet-4-5")
  hooks([{MyApp.Hooks.Redact, []}, {MyApp.Hooks.Audit, on_error: :open}])
end
```

Entries run in list order. A module implements any subset of the callbacks; `use
Normandy.Behaviours.Hooks` checks at compile time that a function named like a callback
has its arity, and warns about a near-miss such as `on_promt`, which would never run.
`BaseAgent.init/1` raises `ArgumentError` for a malformed entry, a module that is not
loaded, an unknown `:on_error`, opts that are not plain data, or opts the module's
`validate_opts!/1` rejects.

### Module hooks and function hooks

| | Hook modules (`hooks`) | Function hooks (`before_hooks`, `after_hooks`) |
|---|---|---|
| Events | all eight | tool calls only |
| Signature | `before_tool(call, ctx, opts)`, `after_tool(call, result, ctx, opts)` | `fn config, call -> … end`, `fn config, call, result -> result end` |
| Persisted | yes, in the session's config template | no, node-local (template supplement) |
| `after_tool` sees | every tool result the model sees | results of tools that ran |
| Order | first | after the modules; a module halt skips them |

Use a function hook only for a closure over a runtime value on one node.

## Events

| Event | Runs | Returns |
|---|---|---|
| `on_session_start(ctx, opts)` | `Turn.Server`, once per start of a session whose store is empty | `{:inject, [text]}` or anything (ignored) |
| `on_prompt(input, ctx, opts)` | before a turn, after input validation, before input guardrails | `{:cont, input}` or `{:halt, reason}` |
| `before_llm(info, ctx, opts)` | before each LLM call; `info` is `%{final: boolean, iterations_left: n}` | `:cont` or `{:halt, reason}` |
| `before_tool(call, ctx, opts)` | before each tool call | `{:cont, call}`, `{:halt, reason}` or `{:halt, %ToolResult{}}` |
| `after_tool(call, result, ctx, opts)` | on every tool result the model will see, once | `{:cont, result}` |
| `after_compact(dropped, meta, ctx, opts)` | after a compaction that removed messages | `{:inject, [text]}` or anything (ignored) |
| `on_turn_end(outcome, ctx, opts)` | after a turn's outcome is delivered | anything (ignored) |
| `on_passivate(ctx, opts)` | `Turn.Server`, before an idle session stops | anything (ignored) |

`on_prompt` receives the validated input: the input schema's struct for a map or struct
input, or the input itself when it is not a map. A rewrite is validated again: a plain map
is cast and checked against the schema, while a value that is already the schema's struct
is trusted, as a caller's would be.

`ctx` is a `%Normandy.Hooks.Context{}`: `event`, `agent_name`, `model`, `session_id`,
`turn_id` (`nil` before a turn starts and in session events) and `values` (the agent's
`tool_context`). It carries no config or credentials.

`after_tool` runs once per result within a server's life, not across a restart: a mixed
approval decision is stored only once the approved calls finish, so a `Turn.Server` that
stops before then asks for the decision again, and the rejected calls' results pass
`after_tool` again.

## Outcomes and halts

| Halt | `BaseAgent` | `Turn.Server.run/2` | `on_turn_end` sees |
|---|---|---|---|
| `on_prompt` | raises `Normandy.HookHaltError` | `{:error, {:rejected, %HookHaltError{}}}` | `{:rejected, %HookHaltError{}}` |
| `before_llm` | raises `Normandy.HookHaltError` | `{:error, {:hook_halted, %HookHaltError{}}}` | `{:error, {:hook_halted, %HookHaltError{}}}` |

`on_turn_end` sees `{:ok, response}` for a completed turn; `{:rejected, exception}` for a
schema, input-guardrail or output-guardrail rejection; `{:error, reason}` otherwise. A
`before_tool` halt is not a turn halt: its result answers the call.

## Errors (`:on_error`)

| Event | `:reraise` (default) | `:open` | `:closed` |
|---|---|---|---|
| `on_prompt`, `before_llm`, `before_tool` | the crash propagates | logged; the value passes on | halts with "hook X crashed: …" |
| `after_tool` | the crash propagates | logged; the result passes on | the result becomes an error result |
| `after_compact`, `on_session_start` | the crash propagates | logged; nothing injected | the crash propagates |
| `on_turn_end`, `on_passivate` | logged | logged | logged |

A return value the library consumes (the `Returns` column above, except "ignored") that is
outside its contract raises `ArgumentError`, whatever `:on_error` says.

In `Turn.Server` no hook outcome stops the session. A crash that propagates (under
`:reraise`, or a contract violation) is reported this way:

| Crash in | `Turn.Server.run/2` replies | `on_turn_end` sees |
|---|---|---|
| `on_prompt` | `{:error, {:handler_crashed, :admit, e}}` | `{:error, {:handler_crashed, :admit, e}}` |
| `before_llm`, `after_compact` | `{:error, {:handler_crashed, :before_llm \| :after_compact, e}}` | the same `{:error, ...}` |
| `after_tool` on a result the server builds (approval rejected or expired, interrupted) | `{:error, {:handler_crashed, :after_tool, e}}` | the same `{:error, ...}` |
| `before_tool`, or `after_tool` inside tool dispatch | `{:error, {:task_down, {e, stacktrace}}}` | the same `{:error, ...}` |
| `on_session_start` | no turn runs: the session waits `:unavailable`, retries, and replies `{:error, {:handler_crashed, :on_session_start, e}}` meanwhile | nothing |

Except on `on_session_start`, the turn fails; the server stays alive. A `before_tool` or
`after_tool` crash inside tool dispatch kills the worker task that runs the tools, hence
`:task_down`; so does a crash in the LLM client or the compactor itself.

## Injection

Injected texts reach the model as user messages, and input guardrails do not run on them.
Label them, and vet any text from an untrusted source before injecting it:

```elixir
{:inject, [~s(<context source="profile">prefers metric units</context>)]}
```

Session-start texts are stored as one message and survive a restart. `after_compact` texts
live in memory only, like the compacted memory itself.

## Compaction and deduplication

`after_compact` receives `dropped`, the `%Normandy.Components.AgentMemory.Entry{}` structs
the compactor removed (`id`, `turn_id`, `role`, original `content`), oldest first. After a
`Turn.Server` session passivates and starts again, it rebuilds the uncompacted
conversation, compaction runs again, and `after_compact` reports the same messages again,
under the same entry ids. Deduplicate on `entry.id`.

## Reaching runtime resources

Hook opts are saved in the session's config template, in plaintext, and must mean the same
on another node after a restart: no pids, functions, references or ports, and no secrets.

- Name processes: a registered name or a `{:via, …}` tuple, not a pid.
- Name modules: `repo: MyApp.Repo`, `store: {MemoryStore.ETS, :my_table}`.
- Read secrets at call time, from application env or your credential provider.
- Derive per-session resources from `ctx.session_id` or `ctx.values`.

A session keeps the hook list it was created with; a hook added to an agent later does not
reach existing sessions. Deploy a hook module to every node before any session uses it: a
node without it keeps such a session `:unavailable` until it is deployed.

## Examples

### Redact a prompt

```elixir
defmodule MyApp.Hooks.Redact do
  use Normandy.Behaviours.Hooks

  alias Normandy.Agents.BaseAgentInputSchema

  @impl true
  def on_prompt(%BaseAgentInputSchema{chat_message: text} = input, _ctx, _opts)
      when is_binary(text),
      do: {:cont, %{input | chat_message: redact(text)}}

  def on_prompt(text, _ctx, _opts) when is_binary(text), do: {:cont, redact(text)}

  # Fail closed: an input this hook cannot read is not let through unredacted.
  def on_prompt(_input, _ctx, _opts), do: {:halt, "unsupported input shape"}

  defp redact(text), do: Regex.replace(~r/\b\d{3}-\d{2}-\d{4}\b/, text, "[ssn]")
end
```

### Inject a profile when a session starts

```elixir
defmodule MyApp.Hooks.Profile do
  use Normandy.Behaviours.Hooks

  @impl true
  def on_session_start(ctx, _opts) do
    case ctx.values[:user_id] do
      nil -> :ok
      user_id -> {:inject, [~s(<context source="profile">) <> profile(user_id) <> "</context>"]}
    end
  end

  defp profile(user_id), do: "user #{user_id} prefers metric units"
end
```

### Save what compaction drops

```elixir
defmodule MyApp.Hooks.SaveDropped do
  use Normandy.Behaviours.Hooks

  # opts: store: {MemoryStore module, handle}, the handle a registered name or table.
  @impl true
  def after_compact(dropped, _meta, ctx, opts) do
    {store, handle} = Keyword.fetch!(opts, :store)
    namespace = Map.fetch!(ctx.values, :memory_namespace)

    Enum.each(dropped, fn entry ->
      # :new conflicts when the path exists, so an entry reported again is not
      # written twice.
      case store.put(handle, namespace, "/memories/compacted/#{entry.id}.md", render(entry), :new) do
        {:ok, _version} -> :ok
        {:error, :conflict} -> :ok
        {:error, reason} -> raise "could not save entry #{entry.id}: #{inspect(reason)}"
      end
    end)
  end

  defp render(%{role: role, content: content}) when is_binary(content), do: "#{role}: #{content}"
  defp render(%{role: role, content: content}), do: "#{role}: #{inspect(content)}"
end
```

### Audit tool results and turns

```elixir
defmodule MyApp.Hooks.Audit do
  use Normandy.Behaviours.Hooks

  require Logger

  @impl true
  def after_tool(call, result, ctx, _opts) do
    Logger.info("tool #{call.name} answered (error: #{result.is_error}) in #{ctx.session_id}")
    {:cont, result}
  end

  @impl true
  def on_turn_end(outcome, ctx, _opts) do
    Logger.info("turn #{ctx.turn_id} ended: #{elem(outcome, 0)}")
  end
end
```

Declare it with `on_error: :open` so a logging failure never fails a tool call.

## Testing a hook

Call the callback directly with a context:

```elixir
defmodule MyAppTest.RedactHookTest do
  use ExUnit.Case, async: true

  alias Normandy.Hooks.{Context, Runner}

  test "redacts an SSN" do
    ctx = %Context{event: :on_prompt}
    assert {:cont, "id [ssn]"} = MyApp.Hooks.Redact.on_prompt("id 123-45-6789", ctx, [])
  end

  test "under the library's rules" do
    config = %{name: "test", behaviours: %{hooks: [{MyApp.Hooks.Redact, []}]}}
    assert Runner.prompt(config, 42) == {:halt, MyApp.Hooks.Redact, "unsupported input shape"}
  end
end
```

`Normandy.Hooks.Runner` applies ordering, `:on_error` and the return contracts, as an
agent would. To receive messages from a hook in a test, register the test process under a
name and pass the name in opts (a pid is refused).

## What hooks do not cover

- `Turn.Inline` has no hook site of its own; tool hooks run there when its `:dispatch`
  calls `Dispatch.dispatch_one/3` with an agent pipeline.
- There is no session-end event: passivation runs `on_passivate`, but a supervisor
  shutdown, `:kill` or node loss runs no callback.
- LLM requests and responses cannot be rewritten.
- `BaseAgent.admit/2,3` runs no hooks.
- Hooks have no timeout.

## Telemetry

Each hook call is a `[:normandy, :hook, :start | :stop | :exception]` span with `event`,
`hook`, `agent_name`, `session_id`, `turn_id` (tool events add `tool_call_id` and `tool`);
`:stop` adds `result`: `:cont`, `:rewrite`, `:halt`, `:inject`, `:ok` or `:rescued`.
`:rescued` is a crash rescued under `:open` or `:closed`, or on `on_turn_end` or
`on_passivate`. `:exception` fires when a crash propagates: under `:reraise`, under
`:closed` on `after_compact` or `on_session_start`, or on a return-contract violation.
