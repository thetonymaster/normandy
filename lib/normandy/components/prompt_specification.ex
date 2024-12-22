defmodule Normandy.Components.PromptSpecification do
  use Normandy.Schema

  schema do
    field :background, {:array, :string}, default: []
    field :steps, {:array, :string}, default: []
    field :output_instructions, {:array, :string}, default: []
    field :additional_information, {:array, :string}, default: []
  end
end
