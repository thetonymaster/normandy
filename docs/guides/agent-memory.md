# Agent memory and tool context

## What it is

`Normandy.Tools.Memory` gives an agent file-like long-term memory under `/memories`. The
model reads and writes it with Anthropic's memory-tool commands (`view`, `create`,
`str_replace`, `insert`, `delete`, `rename`) and curates it itself.

It is separate from the conversation (`Normandy.Components.AgentMemory`, the message
history that compaction trims) and it outlives sessions: documents live in a
`Normandy.Behaviours.MemoryStore` backend, keyed by a namespace your application chooses.
An agent without the tool and without `tool_context` behaves exactly as before.

## Opting in

The tool needs two things: a store (`{module, handle}`) on the tool, and a namespace in
the session's `tool_context`.

Plain `BaseAgent`:

```elixir
alias Normandy.Agents.BaseAgent
alias Normandy.Behaviours.MemoryStore
alias Normandy.Tools.Memory

config =
  BaseAgent.init(%{client: client, model: "claude-sonnet-4-5", tool_context: %{memory_namespace: "acme/user-42"}})
  |> BaseAgent.register_tool(Memory.new(store: {MemoryStore.Postgres, MyApp.Repo}))
```

A `Turn.Session`: the tool goes in the node-local supplement (it holds a store handle, so
it cannot be serialized), and the namespace goes in the config, which is persisted in the
session's config template:

```elixir
alias Normandy.Agents.Turn
alias Normandy.Agents.Turn.Session
alias Normandy.Behaviours.AgentTemplate.Catalog
alias Normandy.Behaviours.SessionRegistry.Native
alias Normandy.Tools.Registry

# Once at boot, on every node (distributed_sessions.md has the full Tier-2 setup).
{:ok, _} = Catalog.start_link(name: MyApp.AgentTemplates)
{:ok, _} = Turn.Supervisor.start_link(name: MyApp.TurnSupervisor)
{:ok, _} = Native.start_link(name: MyApp.SessionRegistry)

:ok =
  Catalog.put(MyApp.AgentTemplates, "support-bot", %{
    tool_registry: Registry.new([Memory.new(store: {MemoryStore.Redis, {redis_conn, "myapp"}})]),
    before_hooks: [],
    after_hooks: [],
    client_builder: fn token -> build_client(token) end
  })

# The session config carries only the namespace; the memory tool comes from the
# supplement. (A Tier-2 config also needs a node-local CredentialProvider in its
# `behaviours`; see distributed_sessions.md.)
session_config =
  BaseAgent.init(%{
    client: client,
    model: "claude-sonnet-4-5",
    tool_context: %{memory_namespace: "acme/user-42"}
  })

Session.run(
  [
    session_id: sid,
    registry: {Native, MyApp.SessionRegistry},
    supervisor: MyApp.TurnSupervisor,
    store: session_store,
    template_provider: {Catalog, MyApp.AgentTemplates},
    template_id: "support-bot",
    config: session_config
  ],
  input
)
```

On first start the template is saved with `tool_context`. On every later start or
rehydration the template is rebuilt, `tool_context` comes back with it, and the tool
registry comes from the supplement. See `distributed_sessions.md` for the rest of the
session options.

The DSL: a store handle such as a Redis connection is not known at compile time, so the
`memory` declaration is static and the store arrives at runtime. `memory/1` rejects
`:store`.

```elixir
defmodule MyAgent do
  use Normandy.DSL.Agent

  agent do
    name "my_agent"
    model "claude-sonnet-4-5"
    memory namespace_key: :memory_namespace, mounts: %{"/memories/org" => {"acme/org-kb", :read_only}}
  end
end

{:ok, agent} =
  MyAgent.new(
    client: client,
    memory_store: {MemoryStore.Redis, conn},
    tool_context: %{memory_namespace: "acme/u-42"}
  )
```

An agent that declares `memory` and gets no `:memory_store` raises `ArgumentError`, and so
does one that gets `:memory_store` without declaring `memory`.

## Namespaces and mounts

The namespace is an opaque non-empty string. It comes from
`tool_context[namespace_key]` (default `:memory_namespace`) and is read on every call. It
is never a field of the tool struct, so the model cannot change it and it survives
`Turn.Server` rehydration. A missing or empty namespace raises `ArgumentError` (surfaced to
the model as an error result); there is no default namespace.

Mounts add other namespaces under sub-paths of `/memories`:

```elixir
Memory.new(
  store: {MemoryStore.Postgres, MyApp.Repo},
  mounts: %{
    "/memories/org" => {"acme/org-kb", :read_only},
    "/memories/team" => {"acme/team-7", :read_write}
  }
)
```

- A path is resolved by longest matching mount prefix; everything else belongs to the
  context namespace.
- A write to a `:read_only` mount returns `Error: {path} is read-only`.
- `rename` across mounts is refused (`Error: cannot rename across mounts`); there is
  no cross-mount move.
- A mount key must be a canonical path under `/memories` (not `/memories` itself and not
  ending in `/`); `new/1` raises otherwise.

## Backends

Every backend implements `Normandy.Behaviours.MemoryStore`: path-addressed documents with
compare-and-set versions and atomic `rename` / `delete_tree`.

**InMemory and ETS** (node-local, lost on restart; for tests and single-node use):

```elixir
store = {MemoryStore.InMemory, MemoryStore.InMemory.new()}
store = {MemoryStore.ETS, MemoryStore.ETS.new()}
```

**Mnesia:** create the table once at boot (`:disc_copies` by default; the default table is
`:normandy_memory_documents`), and use the table name as the handle.

```elixir
MemoryStore.Mnesia.create_tables(table: :my_memory)
store = {MemoryStore.Mnesia, :my_memory}
```

**Postgres:** the handle is your Ecto Repo. Add a host migration:

```elixir
defmodule MyApp.Repo.Migrations.AddNormandyMemory do
  use Ecto.Migration
  def up, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.up()
  def down, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.down()
end

store = {MemoryStore.Postgres, MyApp.Repo}
```

**Redis:** the handle is `{conn, prefix}`, a `Redix` connection and your key prefix.
Documents are hashes and each namespace keeps a sorted set of its paths, written by Lua
scripts so every operation is atomic. A namespace is base64url-encoded into the key and is
one hash tag, so it lives in exactly one Redis Cluster slot: a very large or very hot
namespace cannot be spread across the cluster.

```elixir
{:ok, conn} = Redix.start_link("redis://localhost:6379")
store = {MemoryStore.Redis, {conn, "myapp"}}
```

`MemoryStore.Redis.new/1` defaults to a random test prefix; in production set `:prefix`
(or build the `{conn, "myapp"}` handle yourself) so documents survive a restart and are
found again.

## Limits

| Limit | Default | Where |
| --- | --- | --- |
| `max_document_bytes` | 100_000 | `Memory.new/1`; a larger write returns an error |
| `max_view_chars` | 16_000 | `Memory.new/1`; longer views are cut with a `view_range` hint |
| `max_cas_retries` | 3 | `Memory.new/1`; `str_replace` / `insert` retries on conflict |
| list limit | 1,000 documents | `MemoryStore.list_limit/0`; a longer listing says it stopped |
| path length | 255 bytes | path validation in the memory tool |

## Erasure

Every backend's `delete_namespace/2` callback removes every document in a namespace
atomically. Call it on the backend module with that backend's handle. It is
application-only: the model cannot call it (the tool's `delete` cannot remove `/memories`
itself). Use it for account deletion and data-subject requests.

```elixir
:ok = MemoryStore.Postgres.delete_namespace(MyApp.Repo, "acme/user-42")
```

## Security

- **Memory is a persistent prompt-injection channel.** Anything the model writes is read
  back, with authority, in later sessions. Keep a namespace no wider than the trust
  boundary of the people whose input reaches the agent: a per-user namespace for a
  multi-user agent, and read-only mounts for shared knowledge.
- **No secrets** in memory or in `tool_context`. `tool_context` is persisted in the
  session's config template. Resolve credentials through
  `Normandy.Behaviours.CredentialProvider`, keyed by a value from the context.
  `from_config/2` raises if `tool_context` holds a function or pid.
- **Paths are validated** before any store call: they must start with `/memories`, and
  `..` segments, empty segments, a trailing slash (except on `/memories`), `\`, control
  characters, `%`-escapes (no URL decoding is applied) and paths over 255 bytes are
  rejected.

## Writing contextual tools

Any tool can read the per-session context. Implement `Normandy.Tools.BaseTool` as usual,
plus `Normandy.Tools.ContextualTool.run/2`, which receives a `%Normandy.Tools.Context{}`
(`values` is `tool_context`; also `session_id`, `agent_name`, `turn_id`, `tool_call_id`).
Make `BaseTool.run/1` return an error so a caller that bypasses dispatch fails visibly:

```elixir
defmodule MyApp.Tools.OrderLookup do
  defstruct [:order_id]

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "order_lookup"
    def tool_description(_), do: "Looks up one of the current customer's orders."
    def input_schema(_), do: %{type: "object", properties: %{order_id: %{type: "string"}}, required: ["order_id"]}

    def run(_),
      do: {:error, "order_lookup requires tool context; it was called outside the dispatch pipeline"}
  end

  defimpl Normandy.Tools.ContextualTool do
    def run(%{order_id: id}, %Normandy.Tools.Context{values: %{customer_id: customer}}),
      do: MyApp.Orders.fetch(customer, id)
  end
end
```

The built-in pipelines pass the context to the tool's `execute_fn` (arity 4). A user-supplied
arity-3 `execute_fn` cannot receive context: it still runs ordinary tools, but a contextual
tool run through it returns "<name> requires tool context".

## Telemetry

Each command runs inside a `[:normandy, :memory, :command, :start | :stop | :exception]`
span nested in the tool-execute span, with `bytes_read`, `bytes_written` and `cas_retries`
measurements and `command`, `store`, `status` and `error_type` metadata. Namespace and path
are omitted unless `telemetry_include_paths: true`. See `Normandy.Telemetry` for the full
catalogue.
