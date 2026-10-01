defmodule Normandy.Components.SystemPromptGenerator do
  @moduledoc """
  Generates structured system prompts for agents from prompt specifications.
  """

  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.ContextProvider

  @background "IDENTITY and PURPOSE"
  @steps "INTERNAL ASSISTANT STEPS"
  @output "OUTPUT INSTRUCTIONS"

  @doc """
  Uses an instance of `Normandy.Components.PromptSpecification` to generate a
  system prompt for the agent.

  Tools are not listed here: adapters send them through the API `tools` parameter.

  ## Example

      spec = %PromptSpecification{
        background: ["you are a helpful assistant", "you assist me in assisting"],
        steps: ["step 1", "step 2", "step 3"],
        output_instructions: ["print the result", "as a result"]
      }

      Normandy.Components.SystemPromptGenerator.generate_prompt(spec)
  """
  @spec generate_prompt(PromptSpecification.t()) :: String.t()
  def generate_prompt(%PromptSpecification{background: []} = prompt_specification) do
    generate_prompt(%{
      prompt_specification
      | background: ["This is a conversation with a helpful and friendly AI assistant."]
    })
  end

  def generate_prompt(%PromptSpecification{} = prompt_specification) do
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
    sections = [
      {@background, background},
      {@steps, steps},
      {@output, output}
    ]

    process_sections(sections, [])
  end

  defp build_context(prompt_parts, context_providers) when context_providers == %{} do
    prompt_parts
  end

  defp build_context(prompt_parts, context_providers) do
    {_, result} =
      Enum.map_reduce(context_providers, [], fn {_, provider}, acc ->
        context = ["## #{ContextProvider.title(provider)}", ContextProvider.get_info(provider)]
        {context, acc ++ context}
      end)

    prompt_parts ++
      [
        "# EXTRA INFORMATION AND CONTEXT",
        "Use this information where it is relevant to the request."
      ] ++
      result
  end

  defp process_sections([], prompt_parts), do: prompt_parts

  defp process_sections([{_title, []} | tail], prompt_parts),
    do: process_sections(tail, prompt_parts)

  defp process_sections([{title, content} | tail], prompt_parts) do
    prompt_parts = prompt_parts ++ ["# #{title}"] ++ Enum.map(content, fn x -> "- #{x}" end)
    process_sections(tail, prompt_parts)
  end
end
