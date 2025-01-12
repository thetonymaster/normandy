defmodule Normandy.Agents.BaseAgentConfig do
  use Normandy.Schema

  schema do
    field(:input_schema, :struct)
    field(:output_schema, :struct)
    field(:client, :struct)
    field(:model, :string)
    field(:memory, :struct)
    field(:prompt_specification, :struct)
    field(:initial_memory, :struct)
    field(:current_user_input, :string, default: nil)
    field(:temperature, :float, default: 0.9)
    field(:max_tokens, :integer, default: nil)
  end
end
