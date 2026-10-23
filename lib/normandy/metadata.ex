defmodule Normandy.Metadata do
  @moduledoc """
  The `__meta__` field of a schema struct: the schema module it was built from
  and whether the struct is `:built` (a fresh `struct/1`) or `:loaded` (the
  schema's `__schema__(:loaded)` prototype).

  Nothing in Normandy reads it; it is left out of every JSON encoding and out
  of stored memory.
  """

  defstruct [:state, :schema]

  @type state :: :built | :loaded

  @type t(schema) :: %__MODULE__{
          schema: schema,
          state: state
        }

  @type t :: t(module)

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{state: state}, opts) do
      concat(["#Normandy.Metadata<", to_doc(state, opts), ">"])
    end
  end
end
