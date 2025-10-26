defmodule Normandy.Agents.BaseAgentConfig do
  @moduledoc """
  Configuration structure for BaseAgent instances.

  Stores all stateful information for an agent including schemas,
  memory, model configuration, and prompt specifications.
  """

  use Normandy.Schema

  alias Normandy.Components.PromptSpecification
  alias Normandy.Tools.Registry

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
          max_tokens: pos_integer() | nil,
          tool_registry: Registry.t() | nil,
          max_tool_iterations: pos_integer(),
          retry_options: keyword() | nil,
          circuit_breaker: pid() | nil
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
    field(:tool_registry, :struct, default: nil)
    field(:max_tool_iterations, :integer, default: 5)
    field(:retry_options, :map, default: nil)
    field(:circuit_breaker, :any, default: nil)
  end
end
