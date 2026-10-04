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
  `:max_document_bytes` (100_000), `:max_namespace_bytes` (1_000_000), `:max_view_chars`
  (16_000), `:max_cas_retries` (3), `:telemetry_include_paths` (false).

  `:max_namespace_bytes` (a positive integer, or `nil` for no cap) bounds the total size of
  the documents in a namespace: `create`, `str_replace` and `insert` that would push the
  namespace past it are refused with error type `:namespace_full`. The stores keep a
  namespace as one unit, so its cost grows with its size. The cap is approximate: two
  concurrent writers can each pass the check and together exceed it, and it only sees the
  first #{Normandy.Behaviours.MemoryStore.list_limit()} documents of a namespace (the store's list limit), so a
  namespace with more is under-counted. A mount's cap applies to the mount's namespace.

  Memory carries content across sessions, so it is a prompt-injection channel that
  persists: keep a namespace no wider than the trust boundary of the people whose input
  reaches the agent. Never store secrets in memory.
  """

  alias Normandy.Tools.Context
  alias Normandy.Tools.Memory.{Commands, Paths}

  @enforce_keys [:store]
  defstruct store: nil,
            namespace_key: :memory_namespace,
            mounts: %{},
            max_document_bytes: 100_000,
            max_namespace_bytes: 1_000_000,
            max_view_chars: 16_000,
            max_cas_retries: 3,
            telemetry_include_paths: false,
            command: nil

  @type t :: %__MODULE__{
          store: {module(), term()},
          namespace_key: atom(),
          mounts: %{String.t() => {String.t(), :read_only | :read_write}},
          max_document_bytes: pos_integer(),
          max_namespace_bytes: pos_integer() | nil,
          max_view_chars: pos_integer(),
          max_cas_retries: non_neg_integer(),
          telemetry_include_paths: boolean(),
          command: map() | nil
        }

  @options [
    :store,
    :namespace_key,
    :mounts,
    :max_document_bytes,
    :max_namespace_bytes,
    :max_view_chars,
    :max_cas_retries,
    :telemetry_include_paths
  ]
  @fields ~w(command path view_range file_text old_str new_str insert_line insert_text old_path new_path)a
  @commands ~w(view create str_replace insert delete rename)

  @doc "Builds the tool, validating every option; raises `ArgumentError` naming a bad one."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      [key | _] ->
        raise ArgumentError,
              "Normandy.Tools.Memory.new/1: unknown option #{inspect(key)}; allowed: #{Enum.map_join(@options, ", ", &inspect/1)}"
    end

    unless Keyword.has_key?(opts, :store),
      do:
        raise(ArgumentError, "Normandy.Tools.Memory.new/1: :store is required: {module, handle}")

    tool = struct!(__MODULE__, opts)
    validate_store!(tool.store)
    validate_mounts!(tool.mounts)
    check!(:namespace_key, tool.namespace_key, is_atom(tool.namespace_key), "an atom")
    for key <- [:max_document_bytes, :max_view_chars], do: positive!(key, Map.fetch!(tool, key))

    check!(
      :max_namespace_bytes,
      tool.max_namespace_bytes,
      is_nil(tool.max_namespace_bytes) or
        (is_integer(tool.max_namespace_bytes) and tool.max_namespace_bytes > 0),
      "a positive integer or nil"
    )

    check!(
      :max_cas_retries,
      tool.max_cas_retries,
      is_integer(tool.max_cas_retries) and tool.max_cas_retries >= 0,
      "a non-negative integer"
    )

    check!(
      :telemetry_include_paths,
      tool.telemetry_include_paths,
      is_boolean(tool.telemetry_include_paths),
      "a boolean"
    )

    tool
  end

  @doc false
  # Called by dispatch instead of struct/2: model input fills :command and nothing else.
  @spec prepare_input(t(), map()) :: t()
  def prepare_input(%__MODULE__{} = tool, input) when is_map(input) do
    %{
      tool
      | command: Map.new(@fields, &{&1, Map.get(input, Atom.to_string(&1), Map.get(input, &1))})
    }
  end

  @doc false
  @spec run(t(), Context.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%__MODULE__{} = tool, %Context{} = ctx) do
    namespace = namespace!(tool, ctx)
    meta = telemetry_metadata(tool, namespace)

    :telemetry.span([:normandy, :memory, :command], meta, fn ->
      # :start can only name the session namespace; by :stop the path has been resolved,
      # so a mounted path reports the mount's namespace.
      stop_meta = stop_namespace(meta, tool, namespace)

      case Commands.run(tool, namespace) do
        {:ok, text, stats} ->
          {{:ok, text}, measurements(stats), Map.put(stop_meta, :status, :ok)}

        {:error, type, text} ->
          {{:error, text}, measurements(%{}),
           Map.merge(stop_meta, %{status: :error, error_type: type})}
      end
    end)
  end

  @doc false
  def input_schema do
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

  @doc false
  def description(%__MODULE__{mounts: mounts}) do
    base = """
    Persistent memory that survives across conversations, stored as files under /memories.
    IMPORTANT: ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE.
    MEMORY PROTOCOL:
    1. Use the `view` command to check for earlier progress.
    2. As you make progress, record status, progress and thoughts in your memory.
    ASSUME INTERRUPTION: your context window might be reset at any moment, so you risk losing any progress that is not recorded in your memory directory.
    Keep the directory up to date, coherent and organized: rename or delete files that are no longer relevant, and do not create new files unless necessary. Never store secrets.
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
        ns

      _ ->
        raise ArgumentError,
              "memory tool needs tool_context[#{inspect(tool.namespace_key)}] to be a non-empty string; " <>
                "got keys #{inspect(Map.keys(ctx.values))}"
    end
  end

  defp telemetry_metadata(%__MODULE__{store: {mod, _}, command: cmd} = tool, namespace) do
    # only a known name reaches telemetry: the model's raw value would be unbounded
    base = %{command: if(cmd && cmd.command in @commands, do: cmd.command), store: mod}

    if tool.telemetry_include_paths,
      do: Map.merge(base, %{namespace: namespace, path: cmd && (cmd.path || cmd.old_path)}),
      else: base
  end

  defp stop_namespace(%{namespace: _} = meta, tool, session_ns),
    do: %{meta | namespace: Commands.namespace(tool, session_ns)}

  defp stop_namespace(meta, _tool, _session_ns), do: meta

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
        "Normandy.Tools.Memory.new/1: :store must be {module, handle}, got: #{inspect(other)}"
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
  end

  defp validate_mounts!(other), do: bad_mount!(other)

  @spec bad_mount!(term()) :: no_return()
  defp bad_mount!(what),
    do:
      raise(
        ArgumentError,
        "Normandy.Tools.Memory.new/1: :mounts must map a path under /memories (not /memories itself) " <>
          "to {namespace, :read_only | :read_write}; bad entry: #{inspect(what)}"
      )

  defp positive!(key, value),
    do: check!(key, value, is_integer(value) and value > 0, "a positive integer")

  defp check!(_key, _value, true, _want), do: :ok

  defp check!(key, value, false, want),
    do:
      raise(
        ArgumentError,
        "Normandy.Tools.Memory.new/1: #{inspect(key)} must be #{want}, got: #{inspect(value)}"
      )

  defimpl Normandy.Tools.BaseTool do
    alias Normandy.Tools.Memory

    def tool_name(_tool), do: "memory"
    def tool_description(tool), do: Memory.description(tool)
    def input_schema(_tool), do: Memory.input_schema()

    def run(_tool),
      do: {:error, "memory requires tool context; it was called outside the dispatch pipeline"}
  end

  defimpl Normandy.Tools.ContextualTool do
    alias Normandy.Tools.Memory

    def run(tool, ctx), do: Memory.run(tool, ctx)
  end
end
