defmodule Normandy.Agents.BaseAgent do
  @moduledoc """
  Core agent implementation providing conversational AI capabilities.

  BaseAgent manages agent state, memory, and LLM interactions through a
  stateful configuration approach.
  """

  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Components.Message
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.AgentMemory
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentConfig

  alias Normandy.Tools.Registry

  @type config_input :: %{
          required(:client) => struct(),
          required(:model) => String.t(),
          required(:temperature) => float(),
          optional(:input_schema) => struct(),
          optional(:output_schema) => struct(),
          optional(:memory) => map(),
          optional(:prompt_specification) => PromptSpecification.t(),
          optional(:max_tokens) => pos_integer() | nil,
          optional(:tool_registry) => Registry.t(),
          optional(:max_tool_iterations) => pos_integer()
        }

  @spec init(config_input()) :: BaseAgentConfig.t()
  def init(config) do
    %BaseAgentConfig{
      input_schema: Map.get(config, :input_schema, nil) || %BaseAgentInputSchema{},
      output_schema: Map.get(config, :output_schema, nil) || %BaseAgentOutputSchema{},
      memory: Map.get(config, :memory, nil) || AgentMemory.new_memory(),
      initial_memory: Map.get(config, :memory, nil) || AgentMemory.new_memory(),
      prompt_specification: Map.get(config, :prompt_specification) || %PromptSpecification{},
      client: config.client,
      model: config.model,
      current_user_input: nil,
      temperature: config.temperature,
      max_tokens: Map.get(config, :max_tokens, nil),
      tool_registry: Map.get(config, :tool_registry, nil),
      max_tool_iterations: Map.get(config, :max_tool_iterations, 5)
    }
  end

  @spec reset_memory(BaseAgentConfig.t()) :: BaseAgentConfig.t()
  def reset_memory(config = %BaseAgentConfig{initial_memory: memory}) do
    Map.put(config, :memory, memory)
  end

  @spec get_response(BaseAgentConfig.t(), struct() | nil) :: struct()
  def get_response(
        config = %BaseAgentConfig{prompt_specification: prompt_specification},
        response_model \\ nil
      ) do
    response_model =
      if response_model != nil do
        response_model
      else
        Map.get(config, :output_schema)
      end

    messages =
      [
        %Message{
          role: "system",
          content:
            SystemPromptGenerator.generate_prompt(prompt_specification, config.tool_registry)
        }
      ] ++ AgentMemory.history(config.memory)

    # Prepare tool schemas if tools are available
    opts =
      if has_tools?(config) do
        tool_schemas = Registry.to_tool_schemas(config.tool_registry)
        [tools: tool_schemas]
      else
        []
      end

    Normandy.Agents.Model.converse(
      config.client,
      config.model,
      config.temperature,
      config.max_tokens,
      messages,
      response_model,
      opts
    )
  end

  @spec run(BaseAgentConfig.t(), struct() | nil) :: {BaseAgentConfig.t(), struct()}
  def run(
        config = %BaseAgentConfig{memory: memory, output_schema: output_schema},
        user_input \\ nil
      ) do
    memory =
      if user_input != nil do
        memory
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", user_input)
      end

    config =
      if user_input != nil do
        config
        |> Map.put(:current_user_input, user_input)
        |> Map.put(:memory, memory)
      end

    response = get_response(config, output_schema)
    memory = AgentMemory.add_message(memory, "assistant", response)

    config = Map.put(config, :memory, memory)

    {config, response}
  end

  @spec get_context_provider(BaseAgentConfig.t(), atom()) :: struct()
  def get_context_provider(
        %BaseAgentConfig{prompt_specification: prompt_specification},
        provider_name
      ) do
    context_provider =
      Map.get(prompt_specification, :context_providers, nil)
      |> Map.get(provider_name, nil)

    if context_provider == nil do
      raise Normandy.NonExistentContextProvider, value: provider_name
    else
      context_provider
    end
  end

  @spec register_context_provider(BaseAgentConfig.t(), atom(), struct()) ::
          BaseAgentConfig.t()
  def register_context_provider(
        config = %BaseAgentConfig{prompt_specification: prompt_specification},
        provider_name,
        provider
      ) do
    context_providers =
      prompt_specification.context_providers
      |> Map.put(provider_name, provider)

    prompt_specification = Map.put(prompt_specification, :context_providers, context_providers)
    Map.put(config, :prompt_specification, prompt_specification)
  end

  @spec delete_context_provider(BaseAgentConfig.t(), atom()) :: BaseAgentConfig.t()
  def delete_context_provider(
        config = %BaseAgentConfig{prompt_specification: prompt_specification},
        provider_name
      ) do
    context_providers =
      prompt_specification.context_providers
      |> Map.delete(provider_name)

    prompt_specification = Map.put(prompt_specification, :context_providers, context_providers)
    Map.put(config, :prompt_specification, prompt_specification)
  end

  # Tool management functions

  @doc """
  Registers a tool in the agent's tool registry.

  Creates a new registry if one doesn't exist.

  ## Examples

      iex> agent = BaseAgent.init(config)
      iex> tool = %Normandy.Tools.Examples.Calculator{}
      iex> agent = BaseAgent.register_tool(agent, tool)

  """
  @spec register_tool(BaseAgentConfig.t(), struct()) :: BaseAgentConfig.t()
  def register_tool(%BaseAgentConfig{tool_registry: nil} = config, tool) do
    registry = Registry.new([tool])
    %{config | tool_registry: registry}
  end

  def register_tool(%BaseAgentConfig{tool_registry: registry} = config, tool) do
    updated_registry = Registry.register(registry, tool)
    %{config | tool_registry: updated_registry}
  end

  @doc """
  Gets a tool from the agent's tool registry by name.

  ## Examples

      iex> agent = BaseAgent.register_tool(agent, %Calculator{})
      iex> BaseAgent.get_tool(agent, "calculator")
      {:ok, %Calculator{}}

  """
  @spec get_tool(BaseAgentConfig.t(), String.t()) :: {:ok, struct()} | :error
  def get_tool(%BaseAgentConfig{tool_registry: nil}, _tool_name), do: :error

  def get_tool(%BaseAgentConfig{tool_registry: registry}, tool_name) do
    Registry.get(registry, tool_name)
  end

  @doc """
  Lists all tools available to the agent.

  ## Examples

      iex> BaseAgent.list_tools(agent)
      [%Calculator{}, %StringManipulator{}]

  """
  @spec list_tools(BaseAgentConfig.t()) :: [struct()]
  def list_tools(%BaseAgentConfig{tool_registry: nil}), do: []

  def list_tools(%BaseAgentConfig{tool_registry: registry}) do
    Registry.list(registry)
  end

  @doc """
  Checks if the agent has any tools registered.

  ## Examples

      iex> BaseAgent.has_tools?(agent)
      true

  """
  @spec has_tools?(BaseAgentConfig.t()) :: boolean()
  def has_tools?(%BaseAgentConfig{tool_registry: nil}), do: false
  def has_tools?(%BaseAgentConfig{tool_registry: registry}), do: Registry.count(registry) > 0
end
