defmodule Normandy.Schemas.MemoryConfig do
  use TypedStruct

  typedstruct do
    field :max_history, integer(), default: 0
    field :current_turn_id, String.t()
    field :history, list(), default: []
  end
end
