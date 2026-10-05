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
end
