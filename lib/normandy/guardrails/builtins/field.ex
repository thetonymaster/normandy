defmodule Normandy.Guardrails.Builtins.Field do
  @moduledoc false
  # The value a built-in guard checks: the whole value, or one field of it when
  # the guard has a :field option. A field the struct does not have is a config
  # typo that would read as nil and pass everything, so it raises.

  alias Normandy.Components.ContentBlock.Describe

  @spec extract!(module(), term(), atom() | nil) :: term()
  # The default input schema's content is its text: a guard with no :field checks the
  # text for `run(agent, "x")` and `run(agent, %{chat_message: "x"})` alike.
  def extract!(_guard, %Normandy.Agents.BaseAgentInputSchema{chat_message: text}, nil), do: text
  def extract!(_guard, value, nil), do: value

  def extract!(guard, %mod{} = struct, field) do
    if Map.has_key?(struct, field) do
      Map.get(struct, field)
    else
      raise ArgumentError,
            "#{inspect(guard)}: :field #{inspect(field)} is not a field of %#{inspect(mod)}{}"
    end
  end

  def extract!(_guard, value, field) when is_map(value), do: Map.get(value, field)

  def extract!(guard, value, field) do
    raise ArgumentError,
          "#{inspect(guard)} expected a map or struct when using :field #{inspect(field)}, got " <>
            Describe.type_of(value)
  end

  @doc false
  # The string a guard checks: `extract!/3`, then nil stays nil and anything but a string
  # raises (a string guard on a non-string is a configuration bug, not a violation).
  @spec string!(module(), term(), atom() | nil) :: nil | String.t()
  def string!(guard, value, field) do
    case extract!(guard, value, field) do
      nil ->
        nil

      string when is_binary(string) ->
        string

      other ->
        raise ArgumentError,
              "#{inspect(guard)} expected a string#{field_suffix(field)}, got: #{inspect(other)}"
    end
  end

  @doc false
  # A violation's `:path` for a guard with an optional `:field`.
  @spec path(atom() | nil) :: [atom()]
  def path(nil), do: []
  def path(field), do: [field]

  defp field_suffix(nil), do: ""
  defp field_suffix(field), do: " at field #{inspect(field)}"
end
