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
  option a `:type_doc` in its schema.
  """

  alias NimbleOptions.ValidationError
  alias Normandy.Components.ContentBlock.Describe

  @sensitive_keys [
    :api_key,
    :authorization,
    :client,
    :credential,
    :headers,
    :mcp_servers,
    :password,
    :req_options,
    :secret,
    :token
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
      Exception.message(error)
    end
  end

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
