defmodule Normandy.Metadata do
  @moduledoc """
  Metadata attached to schema structs.

  Tracks the state, source, and context information for schema instances.
  Used internally by the Schema system to manage struct lifecycle.
  """

  defstruct [:state, :source, :context, :schema]

  @type state :: :built | :loaded | :deleted

  @type context :: any

  @type t(schema) :: %__MODULE__{
          context: context,
          schema: schema,
          state: state
        }

  @type t :: t(module)

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(metadata, opts) do
      %{source: source, state: state, context: context} = metadata

      entries =
        for entry <- [state, source, context],
            entry != nil,
            do: to_doc(entry, opts)

      concat(["#Normandy.Metadata<"] ++ Enum.intersperse(entries, ", ") ++ [">"])
    end
  end
end
