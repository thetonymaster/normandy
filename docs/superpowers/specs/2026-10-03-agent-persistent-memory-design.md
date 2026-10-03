# Agent persistent memory and tool context — design

Date: 2026-10-03. Branch: `feat/claudio-0.7-migration` (Normandy 2.0).
Source: `docs/assessments/2026-07-01-framework-workflow-assessment.md`, feature candidate 4
("Long-term memory layer … Nothing of the kind exists today"); brainstorm with Q, 2026-10-03.

## Problem

An agent's only memory is its conversation: `AgentMemory`, an entry graph persisted per
`session_id` by `SessionStore` (InMemory, ETS, Postgres, Redis, Mnesia). Nothing outlives a
session. An agent cannot keep what it learned about a user or a task and read it back in a
later session.

Adding a memory tool exposes a second gap: **tools get no runtime context.**

- `BaseTool.run/1` receives only the tool struct. A tool cannot learn the session, agent or
  user it runs for.
- Configuration baked into a tool struct does not survive rehydration. `Turn.Server` rebuilds
  `tool_registry` from the `AgentTemplate` supplement (`server.ex:344`), and that supplement
  is registered per `template_id` at node boot (`agent_template.ex:10`), so it is the same for
  every session of a template. A per-user namespace stored in a tool struct holds until the
  session first passivates or moves node. After that, every session of the template reads
  and writes the boot-time namespace, and users share memory without any error.
- The DSL builds tools with `struct(tool_module)` (`dsl/agent.ex:594`), so a DSL agent cannot
  give a tool any per-user configuration.
- `Dispatch.prepare_tool/2` merges model input into the tool struct for every key that
  matches a struct field (`dispatch.ex:116`). A configuration field such as `namespace` could
  therefore be overwritten by the model, unless the tool defines `prepare_input/2`.

## Decisions (approved by Q)

1. **Memory shape.** Agent-curated notes: path-addressed text documents, the shape of
   Anthropic's native memory tool. No key/value fact store, no embeddings or semantic recall.
2. **Namespace.** An opaque, caller-chosen string. The library gives it no tenancy meaning.
   Optional read-only mounts expose another namespace, such as org knowledge, without write
   access.
3. **Tool context is in scope.** Per-session context is plain data on `BaseAgentConfig`
   (`tool_context`), carried in `ConfigTemplate`. There is no resolver behaviour.
4. **Tool surface.** Mirror the native `memory_20250818` command set and strings: `view`,
   `create`, `str_replace`, `insert`, `delete`, `rename`.
5. **Concurrency.** Optimistic versioning (compare-and-set) in the store. Edit logic lives once,
   in the tool.
6. **`delete_namespace/2` ships in 2.0** as an app-only erasure API (GDPR-style). The model
   cannot reach it.

## Design

### 1. Tool context

**Config field.** `BaseAgentConfig` gains `field(:tool_context, :map, default: %{})`.
`ConfigTemplate` adds `:tool_context` to `@data_fields`:

- It is persisted and rebuilt with the template.
- A template saved before this field existed rebuilds with `%{}`.
- `from_config/2` already raises on a function or pid anywhere in the template, and that
  check covers this field too.

The moduledoc states that `tool_context` must hold no secrets. The template is deliberately
secret-free and is stored in plaintext. Secrets go through `CredentialProvider`, keyed by a
non-secret value from `tool_context` such as a `tenant_id`.

**Context struct.** The context is a struct rather than a map, so that a typo fails at compile
time and app keys cannot shadow framework keys. It is built per call by `Context.build/2`:

```elixir
defmodule Normandy.Tools.Context do
  @enforce_keys [:tool_call_id]
  defstruct [:session_id, :agent_name, :turn_id, :tool_call_id, values: %{}]

  @spec build(BaseAgentConfig.t(), ToolCall.t()) :: t()
  def build(config, call) do
    %__MODULE__{
      session_id: config.session_id,                 # nil outside Turn.Server sessions
      agent_name: config.name,
      turn_id: config.memory && config.memory.current_turn_id,
      tool_call_id: call.id,
      values: config.tool_context || %{}
    }
  end
end
```

**Opt-in protocol.**

```elixir
defprotocol Normandy.Tools.ContextualTool do
  @spec run(struct(), Normandy.Tools.Context.t()) :: {:ok, term()} | {:error, String.t()}
  def run(tool, ctx)
end
```

A contextual tool still implements `BaseTool`, for `tool_name`, `tool_description` and
`input_schema`. Its `BaseTool.run/1` returns
`{:error, "<name> requires tool context; it was called outside the dispatch pipeline"}`.
A caller that bypasses dispatch therefore fails with an error and does not run without a
namespace.

**Execution.**

- `Executor.execute_tool_classified/2` and `execute_tool/2` accept a `context:` option. When
  `ContextualTool.impl_for(tool)` is non-nil they call `ContextualTool.run(tool, ctx)`, and
  otherwise `BaseTool.run(tool)`. Existing tools are unchanged.
- A contextual tool executed with no `context:` gets the same "requires tool context" error,
  classified `:exception`.
- `execute_parallel/3` and `execute_sequential/3` accept `context:` and forward it unchanged.
  Those APIs are not on the dispatch path, so a caller that needs per-call ids must pass them.

**Where context is built.** Built in the `execute_fn`, with no change to `Dispatch`'s
signatures. Every built-in pipeline already calls `execute_fn` with
`(config, prepared, name, call)`, so it has what `Context.build/2` needs:

- `BaseAgent.span_execute/4` (`base_agent.ex:1812`) passes
  `context: Context.build(config, call)`.
- `Dispatch.default_pipeline/0` (`dispatch.ex:90`) becomes arity 4 and does the same.
- Any `execute_fn` produced by `Behaviours.Config.to_pipeline/1` does the same. This is an
  implementation-plan check: list every `execute_fn` construction site and update each.
- A user-supplied arity-3 `execute_fn` has no `call`. A contextual tool run through it
  returns the "requires tool context" error. This is documented, and nothing falls back
  silently.

Model input never reaches the context, because the context sits outside the tool struct.

### 2. `MemoryStore` behaviour

`Normandy.Behaviours.MemoryStore`. This is a separate behaviour, not an extension of
`SessionStore`: memory outlives sessions and has its own lifecycle. It can share a
connection (Repo, Redix conn, Mnesia node) with the session store.

```elixir
@type handle :: term()
@type namespace :: String.t()
@type path :: String.t()                 # normalized, validated by the tool
@type version :: pos_integer()
@type expected :: version() | :new | :any

@callback list(handle, namespace, prefix :: path) ::
            {:ok, [%{path: path, size: non_neg_integer(), updated_at: DateTime.t()}]} | {:error, term()}
@callback get(handle, namespace, path) ::
            {:ok, %{content: String.t(), version: version()}} | :not_found | {:error, term()}
@callback put(handle, namespace, path, content :: String.t(), expected) ::
            {:ok, version()} | {:error, :conflict} | {:error, term()}
@callback delete(handle, namespace, path, version() | :any) ::
            :ok | :not_found | {:error, :conflict} | {:error, term()}
@callback delete_tree(handle, namespace, prefix :: path) ::
            {:ok, deleted :: non_neg_integer()} | {:error, term()}
@callback rename(handle, namespace, from :: path, to :: path) ::
            {:ok, moved :: pos_integer()} | :not_found | {:error, :exists} | {:error, term()}
@callback delete_namespace(handle, namespace) :: :ok | {:error, term()}
```

**Semantics.** All backends must pass the same contract test.

- **Missing documents.** A missing document is `:not_found`, which is a value, not an error.
  A backend failure (timeout, lost connection, aborted transaction) is always
  `{:error, reason}`. The two are never conflated, so a timeout can never read as "no
  memory yet". This is the same asymmetry `SessionStore` documents.
- **Versions** count per document, starting at 1 on create and incrementing on every `put`.
  - `put(…, :new)` returns `{:error, :conflict}` when the path exists.
  - `put(…, v)` returns `{:error, :conflict}` when the stored version is not `v`, or when
    the document does not exist.
  - `put(…, :any)` always writes.
- **Prefixes.** `list/3` and `delete_tree/3` match the prefix as an exact path or on a path
  boundary (`prefix <> "/"`), so `/memories/a` never matches `/memories/ab`.
- **Directories exist only as path prefixes.** There are no empty directories.
- **`rename/4` is atomic and handles both cases.**
  - If `from` names a document, that document moves.
  - Otherwise every document under the `from/` prefix moves, keeping its relative path.
  - It returns `{:error, :exists}` if `to` names a document or any document exists under
    `to/`, and `:not_found` if nothing exists at or under `from`.
  - Moved documents keep their versions.
- **`delete_tree/3` is atomic.** It removes `prefix` itself (if it is a document) and every
  document under `prefix/`, and returns the count (0 is not an error).
- **`delete_namespace/2`** is atomic per backend and idempotent: an unknown namespace returns
  `:ok`.
- **`list/3`** returns at most 1,000 entries. A namespace holding more than that is reported
  by the tool, not truncated silently.

**Backends.** Each mirrors its `SessionStore` sibling's handle and setup conventions.

- **`InMemory`**
  - Storage: an Agent holding `%{{ns, path} => doc}`.
  - Atomicity: every operation is one Agent call.
- **`ETS`**
  - Storage: an owner GenServer and a `:set` table `{ns, path} => {content, version, updated_at}`.
    Reads come straight from ETS.
  - Atomicity: writes are serialized through the owner.
- **`Postgres`**
  - Storage: a new table, `normandy_memory_documents (namespace text, path text, content text, version integer, updated_at utc_datetime_usec)`,
    with primary key `(namespace, path)`.
  - Migration: a new `MemoryStore.Postgres.Migration` (`up/0`, `down/0`) that the host calls
    from its own migration, like `SessionStore.Postgres.Migration`.
  - Atomicity:
    - `put` with a version: `UPDATE … WHERE namespace=$1 AND path=$2 AND version=$3`, where 0
      rows means `:conflict`.
    - `put` with `:new`: `INSERT … ON CONFLICT DO NOTHING`, where 0 rows means `:conflict`.
    - `rename` and `delete_tree` run in `Repo.transaction`, and the prefix match escapes
      `%`, `_` and `\` before using `LIKE`.
- **`Redis`**
  - Storage:
    - a hash `{p}:mem:{ns}:doc:{path}` holding `content`, `version` and `updated_at`;
    - a sorted set `{p}:mem:{ns}:idx` of paths, scored 0 and ordered lexically, used for
      `list` and prefixes.
    - The `{ns}` part is a hash tag, so a whole namespace lives on one cluster slot.
  - Atomicity: Lua scripts (`EVALSHA`, with a fallback to `EVAL` when Redis returns
    `NOSCRIPT`) for `put`, `delete`, `delete_tree`, `rename` and `delete_namespace`. Lua is
    new to the codebase. It is the standard way to get compare-and-set on Redis, and
    `WATCH/MULTI` would need a dedicated connection per transaction.
- **`Mnesia`**
  - Storage: a new table, `:normandy_memory_documents`, keyed by `{ns, path}`, created by
    `MemoryStore.Mnesia.create_tables/1`.
  - Atomicity: `:mnesia.transaction`.

### 3. The memory tool — `Normandy.Tools.Memory`

It implements `BaseTool` and `ContextualTool`.

```elixir
%Normandy.Tools.Memory{
  store: {module(), handle},                 # node-local; from the supplement
  namespace_key: :memory_namespace,          # key in ctx.values
  mounts: %{},                               # %{"/memories/org" => {"acme/org-kb", :read_only}}
  max_document_bytes: 100_000,
  max_view_chars: 16_000,
  max_cas_retries: 3,
  telemetry_include_paths: false,
  command: nil                               # this call's input; the only field model input reaches
}
```

- **Construction.** `Memory.new/1` validates every option by hand (the codebase has no
  `NimbleOptions`). A malformed option raises `ArgumentError` naming the option and the value
  it got: a store that is not `{module, handle}` or whose module does not implement
  `MemoryStore`, a mount that is not under `/memories`, a non-positive limit.
- **Model input.** `prepare_input/2` writes the model's input into `command` only. `store`,
  `mounts` and the limits cannot be set by the model.
- **Validation.** `validate_input` is skipped for tools that define `prepare_input/2`
  (`dispatch.ex:143`), so `run/2` validates the command itself.
- **Namespace.** It is `ctx.values[namespace_key]`, read in `run/2`. When it is missing or
  not a non-empty binary, `run/2` raises `ArgumentError`, for example
  "memory tool needs tool_context[:memory_namespace] to be a non-empty string; got keys
  [:tenant]". The executor turns that into an `:exception` error result. There is no default
  namespace.
- **Input schema.** One object: `command` (an enum of the six names), `path`, `view_range`,
  `file_text`, `old_str`, `new_str`, `insert_line`, `insert_text`, `old_path`, `new_path`.
  This matches the native field names exactly.

**Paths.** Every path in every command is validated before any store call.

- **Rejected:** any path that does not start with `/memories`; any `..` segment; empty
  segments (`//`); a trailing slash other than on `/memories` itself; `\`; NUL or control
  characters; any `%`-escape (no URL decoding is ever applied); more than 255 bytes.
- **Mounts.** These are resolved by longest prefix. A path under a mount maps to the mount's
  namespace, with the path rewritten relative to the mount root. All other paths map to the
  context namespace.
- **Writes to a `:read_only` mount** return `Error: {path} is read-only`.
- **A `rename` across two namespaces** returns `Error: cannot rename across mounts`.

**Commands.** Success and error strings follow the native reference. `{:error, msg}` becomes a
`ToolResult` with `is_error: true` (`dispatch.ex:312`).

- **`view`**
  - On a directory, `list` is rendered as
    `Here're the files and directories up to 2 levels deep in {path}, excluding hidden items and node_modules:`
    and then `{size}\t{path}` lines with human-readable sizes, the directory's own line
    first. Hidden (`.`-prefixed) segments are excluded. Viewing `/memories` when it is empty
    returns the header and the root line, not an error. When the namespace holds more than
    1,000 documents, the listing ends with a line that says so.
  - On a file, `get` is rendered as `Here's the content of {path} with line numbers:` and
    then `%6d\t` lines. `view_range: [start, end | -1]` returns a slice of lines. Output past
    `max_view_chars` is cut off with a line saying where to continue with `view_range`.
  - If neither exists: `The path {path} does not exist. Please provide a valid path.`
- **`create`**
  - Calls `put(…, :any)`, which overwrites. Claude's own tool description for the native tool
    says "creates or overwrites", and the reference allows either behaviour.
  - Success: `File created successfully at: {path}`.
- **`str_replace`**
  - Steps: get the document, count matches of `old_str` (`new_str` defaults to `""`), then
    call `put(…, version)`.
  - Errors:
    - `Error: The path {path} does not exist. Please provide a valid path.`
    - ``No replacement was performed, old_str `{old_str}` did not appear verbatim in {path}.``
    - ``No replacement was performed. Multiple occurrences of old_str `{old_str}` in lines: {lines}. Please ensure it is unique``
  - Success: `The memory file has been edited.` and then a numbered snippet of the lines
    around the edit.
- **`insert`**
  - Steps: get the document, check the line, then call `put(…, version)`.
  - Errors:
    - `Error: The path {path} does not exist`
    - ``Error: Invalid `insert_line` parameter: {n}. It should be within the range of lines of the file: [0, {n_lines}]``
  - Success: `The file {path} has been edited.`
- **`delete`**
  - If `path` is a document, it is deleted. Otherwise `delete_tree` is called, which is
    atomic.
  - Error when nothing exists: `Error: The path {path} does not exist`.
  - The root `/memories` is rejected: `Error: cannot delete the /memories directory`.
  - Success: `Successfully deleted {path}`.
- **`rename`**
  - Calls the store's `rename`, which is atomic and covers both files and directories.
  - Errors:
    - `Error: The path {old_path} does not exist`
    - `Error: The destination {new_path} already exists`
    - `Error: cannot rename the /memories directory`
  - Success: `Successfully renamed {old_path} to {new_path}`.

**Compare-and-set loop.** `str_replace` and `insert` retry on `{:error, :conflict}` by
re-reading and re-applying, up to `max_cas_retries`. When the retries run out:
`Error: {path} was changed by another writer {n} times while editing; view it and retry`.

**Limits.**

- A write whose result exceeds `max_document_bytes` returns
  `Error: {path} would be {n} bytes; the limit is {max}`.
- Content must be valid UTF-8, or the call returns an error naming the path.
- Image views are unsupported: storage is text only. Viewing a `.png`, `.jpg` or `.jpeg`
  document shows it as text, if one was ever written as text.

**Backend failures.** Any `{:error, reason}` that is not `:conflict` returns
`Error: memory store unavailable: {inspect(reason)}`, classified `:backend`. It is never
turned into a "does not exist".

**Tool description.** The description is sent on every request. It carries the protocol the
API auto-injects for the native tool, which Normandy cannot rely on because this is a custom
tool:

```
Persistent memory that survives across conversations, stored as files under /memories.
IMPORTANT: ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE.
MEMORY PROTOCOL:
1. Use the `view` command to check for earlier progress.
2. As you make progress, record status, progress and thoughts in your memory.
ASSUME INTERRUPTION: your context window might be reset at any moment, so you risk losing any
progress that is not recorded in your memory directory.
Keep the directory up to date, coherent and organized: rename or delete files that are no
longer relevant, and do not create new files unless necessary. Never store secrets.
```

The command list and the read-only mounts, if any, are appended. The text is static per tool
instance, so it does not break prompt caching.

### 4. Opting in

An agent without the tool and without `tool_context` behaves exactly as today.

```elixir
# Plain BaseAgent
config =
  BaseAgent.init(%{client: c, model: m, tool_context: %{memory_namespace: "acme/user-42"}})
  |> BaseAgent.register_tool(Memory.new(store: {MemoryStore.Postgres, MyApp.Repo}))

# Turn.Server session: tool in the boot-time supplement, namespace in the session's config
AgentTemplate.Local.put(cat, "support_bot", %{
  tool_registry: Registry.new([Memory.new(store: {MemoryStore.Redis, redis_handle})]),
  ...
})
Turn.Session.run(
  [session_id: sid, template_provider: tp, config: %{config | tool_context: %{memory_namespace: "acme/user-42"}}, ...],
  input
)
```

`BaseAgent.init/1` accepts `:tool_context`. In a `Turn.Session`:

1. **First start.** `Turn.Session.run/2` with `:config` and `:template_provider` saves the
   template (`session.ex:121-122`), and that template now includes `tool_context`.
2. **Every later start or rehydration.** The template is rebuilt, `tool_context` comes back
   with it, and the tool registry comes from the supplement.

**DSL.** A memory store handle such as a Redis conn cannot be known at compile time, so the
declaration is static and the store arrives at runtime:

```elixir
agent do
  memory namespace_key: :memory_namespace, mounts: %{"/memories/org" => {"acme/org-kb", :read_only}}
end

MyAgent.new(memory_store: {MemoryStore.Redis, conn}, tool_context: %{memory_namespace: "acme/u-42"})
```

`new/1` builds the tool with `Memory.new/1` from the declaration plus `:memory_store`. A DSL
agent that declares `memory` and is given no `:memory_store` raises `ArgumentError`, for
example "MyAgent declares memory; pass memory_store: {module, handle} to new/1". `new/1` also
accepts `:tool_context` for every DSL agent.

### 5. Telemetry

A new span, `[:normandy, :memory, :command, :start | :stop | :exception]`, nested inside the
existing tool-execute span.

- **Measurements:** `duration` (stop and exception), `bytes_read`, `bytes_written`,
  `cas_retries`.
- **Metadata:** `command`, `store` (module), `status` (`:ok | :error`), and `error_type` when
  the status is `:error`. The `error_type` values are `:not_found`, `:conflict_exhausted`,
  `:invalid_path`, `:read_only`, `:too_large`, `:no_match`, `:ambiguous_match`,
  `:invalid_line`, `:exists`, `:backend`.
- **Off by default:** `namespace` and `path`, because both can carry PII. With
  `telemetry_include_paths: true` they are added.
- Every event is documented in the `Normandy.Telemetry` moduledoc. Without that,
  `test/telemetry/catalogue_test.exs` fails.

### Public contract changes

- **Additions only. Nothing existing changes shape.**
  - `BaseAgentConfig.tool_context`
  - `Normandy.Tools.Context`
  - `Normandy.Tools.ContextualTool`
  - the `context:` option on `Executor`
  - `Normandy.Behaviours.MemoryStore` and its 5 backends, plus the Postgres migration and the
    Mnesia `create_tables/1`
  - `Normandy.Tools.Memory`
  - the DSL `memory` macro, and the DSL `new/1` options `:memory_store` and `:tool_context`
- **The one behavioural change.** `Dispatch.default_pipeline/0`'s `execute_fn` becomes
  arity 4. Its output is the same for non-contextual tools.

## Testing

**`MemoryStore` contract** — `test/support/memory_store_contract.ex`, following
`test/support/session_store_contract.ex`. It covers every callback:

- `:new` conflicts, version conflicts, and `put` with a version on a missing document;
- `delete` with a stale version;
- `rename` of a file and of a directory, onto an existing document, onto a non-empty
  directory, and of a missing path;
- `delete_tree` counts;
- `delete_namespace`, including an unknown namespace;
- isolation between namespaces;
- prefix boundaries (`/a` does not match `/ab`);
- `list` ordering and the 1,000-entry cap;
- `updated_at` moving forward.

Where it runs:

- InMemory, ETS and Mnesia: always.
- Postgres: under `:postgres`.
- Redis: under `:redis`, following the existing tags in `test/test_helper.exs`.

**Concurrency** — following `concurrent_append_{mnesia,redis}_test.exs`, plus Postgres under
its tag. N tasks each run `str_replace` or `insert` through the tool on one shared document,
and the test asserts that every edit is present. In a separate test, concurrent `rename`
against `put` leaves no orphaned or duplicated documents.

**Memory tool** — run against the InMemory store and a stub store:

- each command's success and error strings, exactly as listed in §3;
- `view` rendering: sizes, depth 2, hidden entries, `view_range` with `-1`, `max_view_chars`
  cut-off, the empty root;
- path rejection: each rejected form;
- mount routing and read-only writes, plus rename across mounts;
- running out of compare-and-set retries, using a stub that always returns `:conflict`;
- a backend `{:error, _}` reported as `:backend`, never as "does not exist";
- a missing namespace raises;
- model input cannot set `store`, `mounts` or limits;
- `BaseTool.run/1` returns the "requires tool context" error;
- `Memory.new/1` option errors.

**Tool context.**

- `ContextualTool.run/2` receives the right context through every path: BaseAgent `run`,
  `run_with_tools` and the streaming loop; `Turn.Driver`; `Turn.Inline`; `Turn.Server`.
- **`Turn.Server` after passivation and rehydration on a fresh node** (`:distributed`) is the
  regression this design exists to prevent. Two sessions of one template with different
  namespaces must keep separate memory after rehydration.
- Non-contextual tools behave exactly as before.
- `tool_context` survives a `ConfigTemplate` round-trip.
- A template saved without the field rebuilds with `%{}`.
- `from_config/2` raises on a pid inside `tool_context`.
- An arity-3 `execute_fn` with a contextual tool returns the "requires tool context" error.

**DSL.** `memory` declared without `:memory_store` raises. With the declaration and a store,
the tool is registered and `tool_context` reaches it.

**Telemetry.** The `catalogue_test.exs` check passes. Namespace and path are absent by default
and present with `telemetry_include_paths: true`.

**E2E** — a new `mix e2e` scenario:

- Session 1 tells the agent a fact.
- Session 2 (new `session_id`, same namespace) recalls it.
- Session 3 (a different namespace) does not.
- The memory store is Postgres when the suite's Postgres is up, and InMemory otherwise.

## Docs

- `docs/guides/agent-memory.md`. It covers:
  - concepts and opting in (plain, session, DSL);
  - namespaces and mounts;
  - backends and their setup;
  - limits;
  - erasure through `delete_namespace/2`;
  - **security:** memory carries content across sessions, so it is a prompt-injection channel
    that persists. A namespace should be no wider than the trust boundary of the people
    whose input reaches the agent. Memory and `tool_context` must not hold secrets.
- `MIGRATING-2.0.md`: the new Postgres migration, the Mnesia `create_tables/1`, the
  `tool_context` template field (old templates rebuild with `%{}`), and the arity change
  to `default_pipeline`'s `execute_fn`.
- `CLAUDE.md` architecture entries: `MemoryStore`, `Tools.Memory`, `Tools.Context` and
  `ContextualTool`.
- The `Normandy.Telemetry` moduledoc: the new events.

## Out of scope

- **Semantic or embedding recall, and search.**
- **Version history of documents.**
- **Retention and TTL.** These belong to the "Session operations API" candidate.
- **Encryption at rest.**
- **A context resolver behaviour, and changing context mid-session.**
- **Framework-initiated memory writes,** such as end-of-turn summaries. An after-hook can
  build these later on the same store.
- **The native `memory_20250818` declaration.** Claudio has no support for it. When it gains
  support, `Tools.Memory` can declare the native type with the same handler, strings and
  store. The difference is that the API then injects the protocol itself, so the tool
  description shrinks.
- **An auto-injected `/memories` index in the system prompt.** It would save one `view` round
  trip. Revisit if measurements show the latency matters.
- **Image storage** in memory documents.
