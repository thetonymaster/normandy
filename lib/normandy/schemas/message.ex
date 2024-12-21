defmodule Normandy.Schemas.Message do
  use TypedStruct

  @typedoc """
  Message spec
  """
  typedstruct do
    field :message, String.t()
    field :content, map()
    field :turn_id, String.t() | nil
  end
end
