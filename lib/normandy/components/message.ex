defmodule Normandy.Components.Message do
  use Normandy.Schema

  schema do
    field(:role, :string)
    field(:content, :struct)
    field(:turn_id, :string)
  end
end
