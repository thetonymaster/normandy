defmodule Normandy.CastError do
  @moduledoc """
  Raised when a changeset can't cast a value.
  """
  defexception [:message, :type, :value]

  def exception(opts) do
    type = Keyword.fetch!(opts, :type)
    value = Keyword.fetch!(opts, :value)
    msg = opts[:message] || "cannot cast #{inspect(value)} to #{Normandy.Type.format(type)}"
    %__MODULE__{message: msg, type: type, value: value}
  end
end

# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
defmodule Normandy.NonExistentTurn do
  defexception [:message, :value]

  def exception(opts) do
    value = Keyword.fetch!(opts, :value)

    msg = opts[:message] || "turn #{inspect(value)} does not exist"
    %__MODULE__{message: msg, value: value}
  end
end

# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
defmodule Normandy.NonExistentContextProvider do
  defexception [:message, :value]

  def exception(opts) do
    value = Keyword.fetch!(opts, :value)

    msg = opts[:message] || "context provider #{inspect(value)} does not exist"
    %__MODULE__{message: msg, value: value}
  end
end

defmodule Normandy.InvalidChangesetError do
  @moduledoc """
  Raised when we cannot perform an action because the
  changeset is invalid.
  """
  defexception [:action, :changeset]

  def message(%{action: action, changeset: changeset}) do
    changeset = redact(changeset)
    changes = extract_changes(changeset)
    errors = Normandy.Validate.traverse_errors(changeset, & &1)

    """
    could not perform #{action} because changeset is invalid.

    Errors

    #{pretty(errors)}

    Applied changes

    #{pretty(changes)}

    Params

    #{pretty(changeset.params)}

    Changeset

    #{pretty(changeset)}
    """
  end

  # Exception messages reach logs and error trackers: a redact: true field's
  # value is replaced in the params and changes before anything is printed.
  defp redact(%{data: %mod{}} = changeset) do
    fields =
      if function_exported?(mod, :__schema__, 1), do: mod.__schema__(:redact_fields), else: []

    %{
      changeset
      | params: redact_keys(changeset.params, fields),
        changes: redact_keys(changeset.changes, fields)
    }
  end

  defp redact(changeset), do: changeset

  defp redact_keys(map, []), do: map

  defp redact_keys(map, fields) when is_map(map) do
    names = MapSet.new(fields, &Atom.to_string/1)

    Map.new(map, fn {key, value} ->
      if to_string(key) in names, do: {key, "**redacted**"}, else: {key, value}
    end)
  end

  defp redact_keys(other, _fields), do: other

  defp pretty(term) do
    inspect(term, pretty: true)
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  defp extract_changes(%Normandy.Validate{changes: changes}) do
    Enum.reduce(changes, %{}, fn {key, value}, acc ->
      case value do
        %Normandy.Validate{action: :delete} -> acc
        _ -> Map.put(acc, key, extract_changes(value))
      end
    end)
  end

  defp extract_changes([%Normandy.Validate{action: :delete} | tail]),
    do: extract_changes(tail)

  defp extract_changes([%Normandy.Validate{} = changeset | tail]),
    do: [extract_changes(changeset) | extract_changes(tail)]

  defp extract_changes(other),
    do: other
end

defmodule Normandy.ModelCatalogError do
  @moduledoc """
  Raised when the model catalog can't produce a context window for a turn that
  needs one (an agent with a real compactor and no pinned `:max_tokens`). The
  turn fails; nothing is memoised, so the next turn retries the lookup.
  """
  defexception [:model, :reason]

  @impl true
  def message(%__MODULE__{model: model, reason: reason}) do
    "model catalog lookup failed for #{inspect(model)}: #{inspect(reason)}. " <>
      "Compaction needs the model's context window; pin it with the compactor's " <>
      ":max_tokens option to skip the lookup (required for non-Claude clients)."
  end
end

defmodule Normandy.HookHaltError do
  @moduledoc """
  Raised by `Normandy.Agents.BaseAgent` when an `on_prompt` or `before_llm` hook halts the
  turn. `outcome/1` is how both shells report it: `{:rejected, e}` for `on_prompt` and
  `{:error, {:hook_halted, e}}` for `before_llm`. `Turn.Server` replies `{:error, {:rejected, e}}`
  or `{:error, {:hook_halted, e}}` respectively, and `on_turn_end` hooks receive the outcome.
  """
  defexception [:event, :hook, :reason]

  @type t :: %__MODULE__{event: atom(), hook: module(), reason: String.t()}

  @impl true
  def message(%__MODULE__{event: event, hook: hook, reason: reason}) do
    "hook #{inspect(hook)} halted #{event}: #{reason}"
  end

  @doc """
  An `on_prompt` halt is a rejection (the input never became a turn, nothing is stored):
  `{:rejected, e}`. A `before_llm` halt fails a started turn: `{:error, {:hook_halted, e}}`.
  """
  @spec outcome(t()) :: {:rejected, t()} | {:error, {:hook_halted, t()}}
  def outcome(%__MODULE__{event: :on_prompt} = e), do: {:rejected, e}
  def outcome(%__MODULE__{} = e), do: {:error, {:hook_halted, e}}
end
