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
  BaseAgent.init(%{client: client, model: "claude-opus-5-5", tool_context: %{memory_namespace: "acme/user-42"}})
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
alias Normandy.Tools.Toolset

# Once at boot, on every node (distributed_sessions.md has the full Tier-2 setup).
{:ok, _} = Catalog.start_link(name: MyApp.AgentTemplates)
{:ok, _} = Turn.Supervisor.start_link(name: MyApp.TurnSupervisor)
{:ok, _} = Native.start_link(name: MyApp.SessionRegistry)

:ok =
  Catalog.put(MyApp.AgentTemplates, "support-bot", %{
    toolset: Toolset.new([Memory.new(store: {MemoryStore.Redis, {redis_conn, "myapp"}})]),
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
    model: "claude-opus-5-5",
    tool_context: %{memory_namespace: "acme/user-42"}
  })

session =
  Session.new(
    session_id: sid,
    registry: {Native, MyApp.SessionRegistry},
    supervisor: MyApp.TurnSupervisor,
    store: session_store,
    template_provider: {Catalog, MyApp.AgentTemplates},
    template_id: "support-bot",
    config: session_config
  )

Session.run(session, input)
```

On first start the template is saved with `tool_context`. On every later start or
rehydration the template is rebuilt, `tool_context` comes back with it, and the tool
registry comes from the supplement. `Turn.Session.new/1` lists every session option.

The DSL: a store handle such as a Redis connection is not known at compile time, so the
`memory` declaration is static and the store arrives at runtime. `memory/1` rejects
`:store`.

```elixir
defmodule MyAgent do
  use Normandy.DSL.Agent

  agent do
    name "my_agent"
    model "claude-opus-5-5"
    memory namespace_key: :memory_namespace, mounts: %{"/memories/org" => {"acme/org-kb", :read_only}}
  end
end

agent =
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
- `rename` of a directory into its own subdirectory is refused (`Error: cannot rename
  /memories/a into its own subdirectory /memories/a/b`), and so is a rename that would make
  any path under it longer than 255 bytes (`Error: renaming {from} to {to} would make {path}
  longer than 255 bytes`).
- `create` on a path that is already a directory (it has documents under it) is refused
  with `Error: {path} is a directory; choose a file path`.

## Backends

Every backend implements `Normandy.Behaviours.MemoryStore`: path-addressed documents with
compare-and-set versions and atomic `rename` / `delete_tree`.

**InMemory and ETS** (node-local, lost on restart; for tests and single-node use).
InMemory keeps a whole namespace as one value in one process, so every operation's cost
grows with the namespace's size: use it for tests and small namespaces. ETS keeps one row
per document plus a totals row per namespace, so a `get` or `put` costs the same at any
namespace size; its owner process serializes every write and every listing:

```elixir
store = {MemoryStore.InMemory, MemoryStore.InMemory.new()}
store = {MemoryStore.ETS, MemoryStore.ETS.new()}
```

**Mnesia** (one row per document plus a totals row per namespace, in an `:ordered_set`
table): create the table once at boot (`:disc_copies` by default; the default table is
`:normandy_memory_documents`), and use the table name as the handle. A write locks its
namespace's totals row, so one namespace's writers run one at a time. A listing, rename or
tree delete selects the namespace's rows and locks the whole table while it runs.

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

The migration creates two tables: `normandy_memory_documents`, and
`normandy_memory_namespaces`, which holds each namespace's content bytes and document count
for the caps. Every write locks its namespace's row there first, so the writers of one
namespace run one at a time. Write documents only through the store: a row written by other
SQL is not counted.

**Redis:** the handle is `{conn, prefix}`, a `Redix` connection and your key prefix.
Documents are hashes and each namespace keeps a sorted set of its paths and a counter of
its content bytes, written by Lua scripts so every operation is atomic. A namespace is base64url-encoded into the key and is
one hash tag, so it lives in exactly one Redis Cluster slot: a very large or very hot
namespace cannot be spread across the cluster.

```elixir
{:ok, conn} = Redix.start_link("redis://localhost:6379")
store = {MemoryStore.Redis, {conn, "myapp"}}
```

Operational notes for Redis:

- Run Redis with `maxmemory-policy noeviction`, or with a `volatile-*` policy and no TTLs on
  the memory keys. If Redis evicts keys, a namespace's index (the sorted set) can list paths
  whose documents are gone.
- The Lua scripts read and delete document keys that are not declared in `KEYS` (the script
  builds them from the prefix and path). Every key carries the namespace's hash tag, so stock
  Redis Cluster accepts this. A proxy or Redis-compatible server that insists on declared
  keys (for example Dragonfly in its default mode) may reject the scripts.

`MemoryStore.Redis.new/1` requires `:url` and `:prefix` (or build the `{conn, "myapp"}`
handle yourself): a fixed prefix is what lets documents survive a restart and be found again.

## Limits

| Limit | Default | Where |
| --- | --- | --- |
| `max_document_bytes` | 100_000 | `Memory.new/1`; a larger write returns an error |
| `max_view_chars` | 16_000 | `Memory.new/1`; longer views are cut with a `view_range` hint |
| `max_cas_retries` | 3 | `Memory.new/1`; `str_replace` / `insert` retries on conflict |
| list limit | 1,000 documents | `MemoryStore.list_limit/0`; a longer listing says it stopped |
| `max_namespace_bytes` | 1_000_000 | `Memory.new/1`; `nil` disables the cap; a write that would exceed it returns `Error: memory is full: writing {path} would bring it to {total} bytes; the limit is {max}. Delete or shorten files first.` |
| `max_namespace_documents` | 1000 | `Memory.new/1`; `nil` disables the cap; a `create` that would exceed it returns `Error: memory is full: creating {path} would make {count} files; the limit is {max}. Delete files first.` |
| path length | 255 bytes | path validation in the memory tool |

The two namespace caps are independent, and the store checks them in the same atomic
step as the write (`MemoryStore` `put/6`): two concurrent writers cannot exceed a cap
together, and every document counts, not only the first 1,000 a listing shows. A write
that does not grow the namespace (a shorter replacement, an overwrite of the same size) is
always allowed, so a namespace over a lowered cap can still be shortened. A mount's caps
apply to the mount's namespace.

The Postgres and Redis backends stamp `updated_at` from the application's clock, so across
nodes with clock skew it can move backwards.

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
  rejected. Control and format characters mean the Unicode categories Cc and Cf. Cf also
  covers the zero-width joiner and non-joiner (U+200D, U+200C), which Persian and Indic text
  and emoji sequences use, the soft hyphen (U+00AD) and emoji tag characters, so paths that
  need them are refused.
- **Backend errors are bounded.** When the store fails, the model sees
  `Error: memory store unavailable: ` plus a short reason: an exception is reduced to its
  module name and any other reason is cut at 200 characters. The full reason is logged at
  warning level (`memory store failure: ...`).

## Reserved name

`memory` is the tool's name. `BaseAgent.register_tool/2` raises `ArgumentError` ("a tool
named \"memory\" is already registered; pass replace: true to replace it") when a tool with
that name is registered twice, so do not register another tool named `memory` alongside it.

## Tools that read the session context

Every tool's `run/2` receives a `%Normandy.Tools.Context{}`: `input` is the call's validated
input, `values` is `tool_context`, and `session_id`, `agent_name`, `turn_id` and
`tool_call_id` identify the call.

```elixir
defmodule MyApp.Tools.OrderLookup do
  defmodule Input do
    use Normandy.Schema

    io_schema "Order lookup input" do
      field(:order_id, :string, required: true, description: "the order id")
    end
  end

  use Normandy.Tool,
    name: "order_lookup",
    description: "Looks up one of the current customer's orders.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{order_id: id}, values: %{customer_id: customer}}),
    do: MyApp.Orders.fetch(customer, id)
end
```

The customer comes from `tool_context`, which the model cannot set; the order id comes from
the model and is validated against `Input` before `run/2` is called.

## Telemetry

Each command runs inside a `[:normandy, :memory, :command, :start | :stop | :exception]`
span nested in the tool-execute span, with `bytes_read`, `bytes_written` and `cas_retries`
measurements and `command`, `store`, `status` and `error_type` metadata. Namespace and path
are omitted unless `telemetry_include_paths: true`; then the `:stop` event's `namespace` is
the one the command actually used, so a path inside a mount reports the mount's namespace
(`:start` carries the session namespace). See `Normandy.Telemetry` for the full
catalogue.
