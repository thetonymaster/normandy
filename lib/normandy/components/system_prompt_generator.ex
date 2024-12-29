defmodule Normandy.Components.SystemPromptGenerator do
  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.ContextProvider

  @background "IDENTITY and PURPOSE"
  @steps "INTERNAL ASSISTANT STEPS"
  @output "OUTPUT INSTRUCTIONS"

  @doc """
    Uses an instance Normandy.Components.SystemPromptSpecification to
    generate a system prompt for the agent.

    ## Example
    spec = %{
      background: ["you are a helpful assistant", "you assist me in assisting"],
      steps: ["step 1", "step 2", "step 3"],
      output_instructions: ["print the result", "as a result"]
    }

    Normandy.Components.generate_prompt(spec)
  """
  def generate_prompt(
        prompt_specification = %PromptSpecification{
          background: []
        }
      ) do
    background = ["This is a conversation with a helpful and friendly AI assistant."]

    %PromptSpecification{
      steps: steps,
      output_instructions: output,
      context_providers: context_providers
    } = prompt_specification

    build_prompt(background, steps, output)
    |> build_context(context_providers)
    |> Enum.join("\n")
  end

  def generate_prompt(prompt_specification) do
    %PromptSpecification{
      background: background,
      steps: steps,
      output_instructions: output,
      context_providers: context_providers
    } = prompt_specification

    build_prompt(background, steps, output)
    |> build_context(context_providers)
    |> Enum.join("\n")
  end

  defp build_prompt(background, steps, output) do
    output = output ++ extend_output()

    sections = [
      {@background, background},
      {@steps, steps},
      {@output, output}
    ]

    process_sections(sections, [])
  end

  defp build_context(prompt_parts, context_providers) when context_providers == %{}  do
    prompt_parts
  end
  defp build_context(prompt_parts, context_providers) do
    {_, result} = Enum.map_reduce(context_providers, [],
      fn {_, provider}, acc ->
        context = ["## #{ContextProvider.title(provider)}", ContextProvider.get_info(provider)]
        {context, acc ++ context}
      end)

    prompt_parts ++
    ["# EXTRA INFORMATION AND CONTEXT"]
    ++ result
  end

  defp process_sections([], prompt_parts), do: prompt_parts

  defp process_sections([{_title, []} | tail], prompt_parts),
    do: process_sections(tail, prompt_parts)

  defp process_sections([{title, content} | tail], prompt_parts) do
    prompt_parts = prompt_parts ++ ["# #{title}"] ++ Enum.map(content, fn x -> "- #{x}" end)
    process_sections(tail, prompt_parts)
  end

  defp extend_output do
    [
      "Always respond using the proper JSON schema.",
      "Always use the available additional information and context to enhance the response."
    ]
  end
end
