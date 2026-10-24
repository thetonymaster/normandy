defmodule Normandy.Tools.Memory do
  @moduledoc """
  Persistent agent memory: the `memory` tool. The model reads and writes text files under
  `/memories` with Anthropic's memory-tool commands (`view`, `create`, `str_replace`,
  `insert`, `delete`, `rename`); this tool executes them against a
  `Normandy.Behaviours.MemoryStore`.

  The namespace comes from the session's `tool_context` (`namespace_key`, default
  `:memory_namespace`), never from the tool struct, so it survives `Turn.Server`
  rehydration and the model cannot change it. A missing namespace raises: there is no
  default namespace.

      BaseAgent.init(%{client: c, model: m, tool_context: %{memory_namespace: "acme/user-42"}})
      |> BaseAgent.register_tool(Memory.new(store: {MemoryStore.Postgres, MyApp.Repo}))

  Options (`new/1`): `:store` (required, `{module, handle}`), `:namespace_key`, `:mounts`
  (`%{"/memories/org" => {"acme/org-kb", :read_only | :read_write}}`),
  `:max_document_bytes` (100_000), `:max_namespace_bytes` (1_000_000),
  `:max_namespace_documents` (1000), `:max_view_chars` (16_000), `:max_cas_retries` (3),
  `:telemetry_include_paths` (false).

  `:max_namespace_bytes` bounds the total content bytes of a namespace's documents and
  `:max_namespace_documents` their number; each is a positive integer, or `nil` for no
  cap, and they apply independently. A `create`, `str_replace` or `insert` that would push
  the namespace past either is refused with error type `:namespace_full` and writes
  nothing. The store checks the caps in the same atomic step as the write
  (`Normandy.Behaviours.MemoryStore` `put/6`), so they hold under concurrent writers and
  count every document. A write that does not grow the namespace is always allowed, so a
  namespace over a lowered cap can still be shortened. A mount's caps apply to the
  mount's namespace.

  Memory carries content across sessions, so it is a prompt-injection channel that
  persists: keep a namespace no wider than the trust boundary of the people whose input
  reaches the agent. Never store secrets in memory.

  A mount's access holds only while no session can write its namespace directly, so a
  session namespace equal to a mount's namespace raises (the call fails; the model sees
  the mount path, not the namespace), and two mounts of one namespace with different
  access raise in `new/1`. Never build a namespace from a user-controlled string (a
  username, an org slug) without a fixed prefix that mount namespaces do not use, such as
  `"users/" <> user_id` beside `"shared/org-kb"`.
  """

  use Normandy.Tool, name: "memory"

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Telemetry.Span
  alias Normandy.Tools.Context
  alias Normandy.Tools.Memory.{Commands, Paths}

  @enforce_keys [:store]
  defstruct store: nil,
            namespace_key: :memory_namespace,
            mounts: %{},
            max_document_bytes: 100_000,
            max_namespace_bytes: 1_000_000,
            max_namespace_documents: 1000,
            max_view_chars: 16_000,
            max_cas_retries: 3,
            telemetry_include_paths: false

  @type t :: %__MODULE__{
          store: {module(), term()},
          namespace_key: atom(),
          mounts: %{String.t() => {String.t(), :read_only | :read_write}},
          max_document_bytes: pos_integer(),
          max_namespace_bytes: pos_integer() | nil,
          max_namespace_documents: pos_integer() | nil,
          max_view_chars: pos_integer(),
          max_cas_retries: non_neg_integer(),
          telemetry_include_paths: boolean()
        }

  @schema NimbleOptions.new!(
            store: [
              type: :any,
              required: true,
              type_doc: "`{module, handle}`",
              doc: "The `Normandy.Behaviours.MemoryStore` module and its handle."
            ],
            namespace_key: [
              type: :atom,
              default: :memory_namespace,
              doc: "The `tool_context` key holding the session namespace."
            ],
            mounts: [
              type: {:custom, Normandy.Options, :plain_map, []},
              type_doc: "`%{path => {namespace, :read_only | :read_write}}`",
              default: %{},
              doc: "Shared directories mounted under `/memories`."
            ],
            max_document_bytes: [type: :pos_integer, default: 100_000, doc: "Largest document."],
            max_namespace_bytes: [
              type: {:or, [:pos_integer, nil]},
              type_doc: "`t:pos_integer/0` or `nil`",
              default: 1_000_000,
              doc: "Total content bytes of a namespace; `nil` = no cap."
            ],
            max_namespace_documents: [
              type: {:or, [:pos_integer, nil]},
              type_doc: "`t:pos_integer/0` or `nil`",
              default: 1000,
              doc: "Documents in a namespace; `nil` = no cap."
            ],
            max_view_chars: [type: :pos_integer, default: 16_000, doc: "Longest `view` result."],
            max_cas_retries: [
              type: :non_neg_integer,
              default: 3,
              doc: "Compare-and-set retries of a write."
            ],
            telemetry_include_paths: [
              type: :boolean,
              default: false,
              doc: "Put the namespace and path in telemetry metadata."
            ]
          )
  @fields ~w(command path view_range file_text old_str new_str insert_line insert_text old_path new_path)a
  @commands ~w(view create str_replace insert delete rename)

  @doc """
  Builds the tool, validating every option; raises `ArgumentError` naming a bad one.
  Takes a keyword list or a map.

  ## Options

  #{Normandy.Options.docs(@schema)}
  """
  @spec new(keyword() | map()) :: t()
  def new(opts) do
    opts = Normandy.Options.validate!(opts, @schema, {__MODULE__, :new, 1})
    tool = struct!(__MODULE__, opts)
    validate_store!(tool.store)
    validate_mounts!(tool.mounts)
    tool
  end

  @doc false
  # The command fields of a call's input, atom-keyed for Commands. Dispatch hands run/2 the
  # input Normandy.Tools.Input validated (string keys); a string key beats an atom one.
  @spec command(map()) :: map()
  def command(input) when is_map(input),
    do: Map.new(@fields, &{&1, Map.get(input, Atom.to_string(&1), Map.get(input, &1))})

  @impl Normandy.Tool
  @spec run(t(), Context.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%__MODULE__{} = tool, %Context{input: input} = ctx) do
    namespace = namespace!(tool, ctx)
    cmd = command(input)
    meta = telemetry_metadata(tool, cmd, namespace)

    Span.span([:normandy, :memory, :command], meta, fn ->
      # :start can only name the session namespace; by :stop the path has been resolved,
      # so a mounted path reports the mount's namespace.
      stop_meta = stop_namespace(meta, tool, cmd, namespace)

      case Commands.run(tool, cmd, namespace) do
        {:ok, text, stats} ->
          {{:ok, text}, measurements(stats), Map.put(stop_meta, :status, :ok)}

        {:error, type, text} ->
          {{:error, text}, measurements(%{}),
           Map.merge(stop_meta, %{status: :error, error_type: type})}
      end
    end)
  end

  @impl Normandy.Tool
  def input_schema(_tool) do
    %{
      type: "object",
      properties: %{
        command: %{type: "string", enum: @commands, description: "The memory operation."},
        path: %{
          type: "string",
          description: "A path under /memories (every command except rename)."
        },
        view_range: %{
          type: "array",
          items: %{type: "integer"},
          description: "view only: [start_line, end_line]; end_line -1 reads to the end."
        },
        file_text: %{type: "string", description: "create only: the whole file content."},
        old_str: %{
          type: "string",
          description: "str_replace only: text that occurs exactly once in the file."
        },
        new_str: %{
          type: "string",
          description: "str_replace only: the replacement; omit it to delete old_str."
        },
        insert_line: %{
          type: "integer",
          description: "insert only: insert after this line; 0 inserts at the top."
        },
        insert_text: %{type: "string", description: "insert only: the text to insert."},
        old_path: %{
          type: "string",
          description: "rename only: the file or directory to move."
        },
        new_path: %{type: "string", description: "rename only: where to move it."}
      },
      required: ["command"]
    }
  end

  @impl Normandy.Tool
  def description(%__MODULE__{mounts: mounts}) do
    base = """
    Persistent memory that survives across conversations, stored as files under /memories.
    At the start of a task, view /memories to pick up earlier progress. Record durable progress and decisions as you go; your context may be reset.
    Keep the directory organized: rename or delete files that are no longer relevant, and do not create new files unless necessary. Never store secrets.
    Commands: view (a directory listing or a file with line numbers), create (create or overwrite a file), str_replace, insert, delete (a file or a directory), rename (a file or a directory).\
    """

    case Enum.sort(mounts) do
      [] ->
        base

      list ->
        base <>
          "\nShared directories: " <>
          Enum.map_join(list, ", ", fn {m, {_, a}} -> "#{m} (#{access_label(a)})" end) <> "."
    end
  end

  defp access_label(:read_only), do: "read-only"
  defp access_label(:read_write), do: "read-write"

  defp namespace!(tool, ctx) do
    case Map.get(ctx.values, tool.namespace_key) do
      ns when is_binary(ns) and ns != "" ->
        not_a_mount!(tool, ns)

      _ ->
        raise ArgumentError,
              "memory tool needs tool_context[#{inspect(tool.namespace_key)}] to be a non-empty string; " <>
                "got keys #{inspect(Map.keys(ctx.values))}"
    end
  end

  # A session that could write a mount's namespace directly would bypass the mount's
  # :read_only. Names the mount path only: this message reaches the model.
  defp not_a_mount!(%__MODULE__{mounts: mounts, namespace_key: key}, ns) do
    case Enum.find(Enum.sort(mounts), fn {_mount, {mount_ns, _access}} -> mount_ns == ns end) do
      nil ->
        ns

      {mount, _} ->
        raise ArgumentError,
              "memory tool: tool_context[#{inspect(key)}] equals the namespace of mount " <>
                "#{mount}; a session namespace must differ from every mount's"
    end
  end

  defp telemetry_metadata(%__MODULE__{store: {mod, _}} = tool, cmd, namespace) do
    # only a known name reaches telemetry: the model's raw value would be unbounded
    base = %{command: if(cmd.command in @commands, do: cmd.command), store: mod}

    if tool.telemetry_include_paths,
      do: Map.merge(base, %{namespace: namespace, path: cmd.path || cmd.old_path}),
      else: base
  end

  defp stop_namespace(%{namespace: _} = meta, tool, cmd, session_ns),
    do: %{meta | namespace: Commands.namespace(tool, cmd, session_ns)}

  defp stop_namespace(meta, _tool, _cmd, _session_ns), do: meta

  defp measurements(stats),
    do: Map.merge(%{bytes_read: 0, bytes_written: 0, cas_retries: 0}, stats)

  defp validate_store!({mod, _handle}) when is_atom(mod) do
    behaviours =
      if Code.ensure_loaded?(mod),
        do: Keyword.get_values(mod.module_info(:attributes), :behaviour) |> List.flatten(),
        else: []

    unless Normandy.Behaviours.MemoryStore in behaviours,
      do:
        raise(
          ArgumentError,
          "Normandy.Tools.Memory.new/1: :store module #{inspect(mod)} does not implement Normandy.Behaviours.MemoryStore"
        )
  end

  defp validate_store!(other),
    do:
      raise(
        ArgumentError,
        "Normandy.Tools.Memory.new/1: :store must be {module, handle}, got: " <>
          Describe.type_of(other)
      )

  defp validate_mounts!(mounts) when is_map(mounts) do
    Enum.each(mounts, fn
      {mount, {ns, access}}
      when is_binary(ns) and ns != "" and access in [:read_only, :read_write] ->
        # Exact round-trip: resolve/3 matches the key as written, so a key that validate
        # normalises (e.g. "/memories/") would silently never match.
        unless Paths.validate(mount) == {:ok, mount} and mount != Paths.root(),
          do: bad_mount!(mount)

      {mount, _} ->
        bad_mount!(mount)
    end)

    mounts
    |> Enum.group_by(fn {_mount, {ns, _access}} -> ns end)
    |> Enum.each(fn {_ns, entries} -> same_access!(Enum.sort(entries)) end)
  end

  defp validate_mounts!(other), do: bad_mount!(other)

  # Two mounts of one namespace with different access: the read-write one would write
  # what the read-only one promises not to.
  defp same_access!([{_, {_, access}} | _] = entries) do
    case Enum.find(entries, fn {_mount, {_ns, a}} -> a != access end) do
      nil ->
        :ok

      _ ->
        raise ArgumentError,
              "Normandy.Tools.Memory.new/1: :mounts " <>
                Enum.map_join(entries, " and ", &elem(&1, 0)) <>
                " share a namespace with different access; give one namespace one access"
    end
  end

  @spec bad_mount!(term()) :: no_return()
  defp bad_mount!(what),
    do:
      raise(
        ArgumentError,
        "Normandy.Tools.Memory.new/1: :mounts must map a path under /memories (not /memories itself) " <>
          "to {namespace, :read_only | :read_write}; bad entry: #{inspect(what)}"
      )
end
