defmodule Normandy.Options do
  @moduledoc """
  Option validation for Normandy's public entry points.

  An entry point keeps a `NimbleOptions` schema and calls `validate!/3` with its own
  `{module, function, arity}`. Options may be a keyword list or a map with atom keys. Any
  problem raises `ArgumentError` whose message starts with `Module.function/arity:` and
  names the option:

      Normandy.Agents.BaseAgent.init/1: unknown option :api_kye; supported: :client, :model, ...

  The value of an option named in `sensitive_keys/0`, or nested under one, never appears in
  a message: the message names the option and shows its `:type_doc` instead. Give every such
  option a `:type_doc` in its schema. Whatever the option, a map, list or tuple value is
  never echoed either (it can hold a secret under any key): the message states its type, for
  example `got: a map`. Scalar values appear as NimbleOptions words them.

  ## Timeouts

  Every option a caller waits on is called `:timeout` and takes ms or `:infinity`, except the
  durable server's two `_ms` options (not waits on a call; they also take ms or `:infinity`)
  and the Mnesia stores' `:wait_timeout` (ms or `:infinity`, as `:mnesia.wait_for_tables/2`). A
  `:timeout` that bounds one tool call takes positive ms only: a tool call is always bounded.
  Defaults:

  | Option | Where | Default |
  |---|---|---|
  | `:timeout` | `AgentProcess.run/3` | `:infinity` |
  | `:timeout` | `AgentProcess.update_agent/3` | `:infinity` |
  | `:timeout` | `AgentPool.checkout/2`, `AgentPool.transaction/3` | 5_000 |
  | `:timeout` | `Reactive.race/3`, `all/3`, `some/3` | 60_000 |
  | `:timeout` | `ParallelOrchestrator.execute/3`, `execute_stream/2` | 300_000 per agent |
  | `:timeout` | `Batch.Processor.process_batch/3` and its variants, `BaseAgent.process_batch/3` | 300_000 per item |
  | `:timeout` (positive ms) | `Toolset.register/3`, `BaseAgent.register_tool/3`, DSL `tool Mod, timeout: ms` | the tool call's timeout; unset: 30_000 (`Tools.Executor.default_timeout/0`) |
  | `:timeout` (positive ms) | `Tools.Executor.execute_tool/2`, `execute_tool_classified/2` | 30_000 (the dispatcher passes the registration timeout) |
  | `:timeout` (positive ms) | `A2A.Registry.discover_and_register/3` | 60_000 (each registered tool's timeout) |
  | `:approval_timeout_ms` | `Turn.Server.start_link/1` | 300_000 |
  | `:idle_timeout_ms` | `Turn.Server.start_link/1` | 60_000 |
  | `:wait_timeout` | `SessionStore.Mnesia.create_tables/1`, `MemoryStore.Mnesia.create_tables/1` | 30_000 |
  | (none) | `Turn.Server.run/2` | `:infinity` |

  `CircuitBreaker.start_link/1`'s `:timeout` (60_000) is how long an open breaker waits before
  it lets probe calls through, not a call timeout.
  """

  alias NimbleOptions.ValidationError
  alias Normandy.Components.ContentBlock.Describe

  @sensitive_keys [
    :agent,
    :agent_config,
    :agents,
    :api_key,
    :auth_token,
    :authorization,
    :client,
    :config,
    :context,
    :credential,
    :headers,
    :mcp_servers,
    :password,
    :redix,
    :req_options,
    :secret,
    :store_redix,
    :templates,
    :token,
    :transport_opts,
    :url,
    :workers
  ]

  @doc "Option names whose values are never shown in an error message."
  @spec sensitive_keys() :: [atom()]
  def sensitive_keys, do: @sensitive_keys

  @doc """
  Validates `opts` against `schema` and returns them as a keyword list with the schema's
  defaults filled in.

  Raises `ArgumentError` prefixed with `Module.function/arity:` (from `mfa`) for an unknown
  or duplicated option, a missing required one, a bad value, or `opts` that are neither a
  keyword list nor a map with atom keys.
  """
  @spec validate!(keyword() | map(), NimbleOptions.t(), {module(), atom(), arity()}) ::
          keyword()
  def validate!(opts, %NimbleOptions{} = schema, {mod, fun, arity})
      when is_atom(mod) and is_atom(fun) and is_integer(arity) and arity >= 0 do
    prefix = "#{inspect(mod)}.#{fun}/#{arity}"
    opts = to_keyword!(opts, prefix)
    :ok = check_duplicates!(opts, prefix)

    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} ->
        validated

      {:error, %ValidationError{} = error} ->
        raise ArgumentError, "#{prefix}: #{describe(error, schema)}"
    end
  end

  @doc "The Markdown option list for `schema`, to embed in an `@doc`."
  @spec docs(NimbleOptions.t()) :: String.t()
  def docs(%NimbleOptions{} = schema), do: NimbleOptions.docs(schema)

  @doc false
  # A NimbleOptions custom type: `{:custom, Normandy.Options, :plain_map, []}`. NimbleOptions'
  # own :map and {:map, k, v} raise Protocol.UndefinedError when given a struct. It names the
  # type, never the value.
  @spec plain_map(term()) :: {:ok, map()} | {:error, String.t()}
  def plain_map(value) when is_map(value) and not is_struct(value), do: {:ok, value}

  def plain_map(value),
    do: {:error, "expected a plain map (not a struct), got: #{Describe.type_of(value)}"}

  defp to_keyword!(opts, prefix) when is_list(opts) do
    case Enum.find_index(opts, &(not keyword_entry?(&1))) do
      nil ->
        opts

      index ->
        raise ArgumentError,
              "#{prefix}: expected options as a keyword list or a map, got a list whose " <>
                "element #{index} is #{Describe.type_of(Enum.at(opts, index))}"
    end
  end

  defp to_keyword!(%mod{}, prefix) do
    raise ArgumentError,
          "#{prefix}: expected options as a keyword list or a map, got a " <>
            "%#{inspect(mod)}{} struct"
  end

  defp to_keyword!(opts, prefix) when is_map(opts) do
    case Enum.reject(Map.keys(opts), &is_atom/1) do
      [] -> Map.to_list(opts)
      keys -> raise ArgumentError, "#{prefix}: option names must be atoms, got: #{inspect(keys)}"
    end
  end

  defp to_keyword!(other, prefix) do
    raise ArgumentError,
          "#{prefix}: expected options as a keyword list or a map, got " <>
            Describe.type_of(other)
  end

  defp keyword_entry?({key, _value}) when is_atom(key), do: true
  defp keyword_entry?(_entry), do: false

  defp check_duplicates!(opts, prefix) do
    keys = Keyword.keys(opts)

    case Enum.uniq(keys -- Enum.uniq(keys)) do
      [] -> :ok
      dups -> raise ArgumentError, "#{prefix}: #{option_names(dups)} given more than once"
    end
  end

  # NimbleOptions reports unknown options with the list of them in :key.
  defp describe(%ValidationError{key: keys, keys_path: path}, schema) when is_list(keys) do
    supported = schema.schema |> definition_at(path) |> Keyword.keys()
    "unknown #{option_names(keys)}#{under(path)}; #{supported(supported)}"
  end

  defp describe(%ValidationError{key: key, keys_path: path, value: value} = error, schema) do
    if value != nil and Enum.any?([key | path], &(&1 in @sensitive_keys)) do
      spec = schema.schema |> definition_at(path) |> Keyword.get(key, [])
      expected = Keyword.get(spec, :type_doc) || inspect(Keyword.get(spec, :type))

      "invalid value for #{inspect(key)} option#{under(path)}: expected #{expected}; " <>
        "the value is not shown because #{inspect(key)} can hold a secret"
    else
      message = redact_container(Exception.message(error), value)

      # Under a nested option the failing value is the inner one, so a string there is
      # echoed by NimbleOptions and must be described; only a top-level string is shown.
      if path != [] and is_binary(value) and value != "",
        do: String.replace(message, inspect(value), Describe.type_of(value)),
        else: message
    end
  end

  # A map, list or tuple can hold a secret under any key, so its inspected form is replaced by
  # its type. NimbleOptions' nested errors ({:or}, {:list}, {:tuple}, keyword_list) echo the
  # inner value that failed, not the top one, so every container inside `value` is replaced,
  # longest inspected form first: an inner container's text is part of the outer one's.
  # Strings inside a container are replaced too; a top-level scalar keeps NimbleOptions' own
  # message.
  @doc false
  @spec redact_container(String.t(), term()) :: String.t()
  def redact_container(message, value) do
    value
    |> containers([])
    |> Enum.reject(&(&1 == value and is_binary(&1)))
    |> Enum.map(&{inspect(&1), Describe.type_of(&1)})
    |> Enum.uniq()
    |> Enum.sort_by(fn {inspected, _type} -> String.length(inspected) end, :desc)
    |> Enum.reduce(message, fn {inspected, type}, acc ->
      String.replace(acc, inspected, type)
    end)
  end

  defp containers(value, acc) when is_struct(value),
    do: value |> Map.from_struct() |> Map.values() |> Enum.reduce([value | acc], &containers/2)

  defp containers(value, acc) when is_map(value),
    do: Enum.reduce(value, [value | acc], fn {k, v}, acc -> containers(v, containers(k, acc)) end)

  defp containers(value, acc) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.reduce([value | acc], &containers/2)

  defp containers(value, acc) when is_list(value), do: list_containers(value, [value | acc])
  # A string inside a container is echoed by NimbleOptions' nested errors too; "" is skipped
  # because its inspected form would match unrelated text (its container still hides it).
  defp containers("", acc), do: acc
  defp containers(value, acc) when is_binary(value), do: [value | acc]
  defp containers(_scalar, acc), do: acc

  # Walks an improper list's tail too.
  defp list_containers([head | tail], acc), do: list_containers(tail, containers(head, acc))
  defp list_containers([], acc), do: acc
  defp list_containers(tail, acc), do: containers(tail, acc)

  defp definition_at(definition, []), do: definition

  defp definition_at(definition, [key | rest]),
    do: definition |> Keyword.fetch!(key) |> Keyword.fetch!(:keys) |> definition_at(rest)

  defp option_names([key]), do: "option #{inspect(key)}"
  defp option_names(keys), do: "options #{inspect(keys)}"

  defp supported([]), do: "it takes no options"
  defp supported(keys), do: "supported: " <> Enum.map_join(keys, ", ", &inspect/1)

  defp under([]), do: ""
  defp under(path), do: " in #{Enum.map_join(path, ".", &inspect/1)}"
end
