defmodule Normandy.Agents.BaseAgent do
  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Components.Message
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.AgentMemory
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.BaseAgentInputSchema
  alias Normandy.Agents.BaseAgentConfig

  def init(config) do
    %BaseAgentConfig{
      input_schema: Map.get(config, :input_schema, nil) || %BaseAgentInputSchema{},
      output_schema: Map.get(config, :output_schema, nil) || %BaseAgentOutputSchema{},
      memory: Map.get(config, :memory, nil) ||  AgentMemory.new_memory(),
      initial_memory: Map.get(config, :memory, nil) ||  AgentMemory.new_memory(),
      prompt_specification: Map.get(config, :prompt_specification) || %PromptSpecification{},
      client: config.client,
      model: config.model,
      current_user_input: nil,
      temperature: config.temperature,
      max_tokens: Map.get(config, :max_tokens, nil)
    }
  end

  def reset_memory(config = %BaseAgentConfig{initial_memory: memory}) do
    Map.put(config, :memory, memory)
  end

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
          content: SystemPromptGenerator.generate_prompt(prompt_specification)
        }
      ] ++ AgentMemory.history(config.memory)

    response = Normandy.Agents.Model.converse(
      config.client,
      config.model,
      config.temperature,
      config.max_tokens,
      messages,
      response_model
    )
    {config, response}
  end

  def run(
        config = %BaseAgentConfig{memory: memory, output_schema: output_schema},
        user_input \\ nil
      ) do
    if user_input != nil do
      memory =
        memory
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", user_input)

      ^config =
        config
        |> Map.put(:memory, memory)
        |> Map.put(:current_user_input, user_input)
    end

    response = get_response(config, output_schema)
    memory = AgentMemory.add_message(memory, "assistant", response)

    config = Map.put(config, :memory, memory)

    {config, memory}
  end

  def get_context_provider(
        %BaseAgentConfig{prompt_specification: prompt_specification},
        provider_name
      ) do
    context_provider =
      Map.get(prompt_specification, :context_providers, nil)
      |> Map.get(provider_name, nil)



    if context_provider == nil do
      raise Normandy.NotExistantContexProvider, value: provider_name
    else
      context_provider
    end
  end

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
end
