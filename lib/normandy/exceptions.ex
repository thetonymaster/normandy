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

defmodule Normandy.NonExistentTurn do
  defexception [:message, :value]

  def exception(opts) do
    value = Keyword.fetch!(opts, :value)

    msg = opts[:message] || "turn #{inspect(value)} does not exist"
    %__MODULE__{message: msg, value: value}
  end
end

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
