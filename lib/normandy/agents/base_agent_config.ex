defmodule Normandy.Agents.BaseAgentConfig do
  @moduledoc """
  Configuration structure for BaseAgent instances.

  Stores all stateful information for an agent including schemas,
  memory, model configuration, and prompt specifications.
  """

  use Normandy.Schema

  alias Normandy.Components.PromptSpecification

  @type t :: %__MODULE__{
          input_schema: struct(),
          output_schema: struct(),
          client: struct(),
          model: String.t(),
          memory: map(),
          prompt_specification: PromptSpecification.t(),
          initial_memory: map(),
          current_user_input: String.t() | nil,
          temperature: float(),
          max_tokens: pos_integer() | nil
        }

  schema do
    field(:input_schema, :struct)
    field(:output_schema, :struct)
    field(:client, :struct)
    field(:model, :string)
    field(:memory, :map)
    field(:prompt_specification, :struct)
    field(:initial_memory, :map)
    field(:current_user_input, :string, default: nil)
    field(:temperature, :float, default: 0.9)
    field(:max_tokens, :integer, default: nil)
  end
end
