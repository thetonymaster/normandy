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
  Uses an instance Normandy.Components.SystemPromptSpecification to
  generate a system prompt for the agent.

  ## Example

      spec = %{
        background: ["you are a helpful assistant", "you assist me in assisting"],
        steps: ["step 1", "step 2", "step 3"],
        output_instructions: ["print the result", "as a result"]
      }

      Normandy.Components.generate_prompt(spec)

  ## Parameters
    - prompt_specification: The prompt specification
    - tool_registry: Optional tool registry for including tool information

  """
  @spec generate_prompt(PromptSpecification.t(), any()) :: String.t()
  def generate_prompt(prompt_specification, tool_registry \\ nil)

  def generate_prompt(
        prompt_specification = %PromptSpecification{
          background: []
        },
        tool_registry
      ) do
    background = ["This is a conversation with a helpful and friendly AI assistant."]

    %PromptSpecification{
      steps: steps,
      output_instructions: output,
      context_providers: context_providers
    } = prompt_specification

    build_prompt(background, steps, output)
    |> build_context(context_providers)
    |> build_tools(tool_registry)
    |> Enum.join("\n")
  end

  def generate_prompt(prompt_specification, tool_registry) do
    %PromptSpecification{
      background: background,
      steps: steps,
      output_instructions: output,
      context_providers: context_providers
    } = prompt_specification

    build_prompt(background, steps, output)
    |> build_context(context_providers)
    |> build_tools(tool_registry)
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
      ["# EXTRA INFORMATION AND CONTEXT"] ++
      result
  end

  defp build_tools(prompt_parts, nil), do: prompt_parts

  defp build_tools(prompt_parts, tool_registry) do
    alias Normandy.Tools.Registry
    alias Normandy.Tools.BaseTool

    case Registry.count(tool_registry) do
      0 ->
        prompt_parts

      _ ->
        tools = Registry.list(tool_registry)

        tool_descriptions =
          Enum.map(tools, fn tool ->
            build_tool_documentation(tool)
          end)

        prompt_parts ++
          ["# AVAILABLE TOOLS", "You have access to the following tools:"] ++
          tool_descriptions
    end
  end

  defp build_tool_documentation(tool) do
    alias Normandy.Tools.BaseTool

    name = BaseTool.tool_name(tool)
    description = BaseTool.tool_description(tool)
    schema = BaseTool.input_schema(tool)

    header = "## #{name}\n#{description}"

    # Build parameter documentation from schema
    params_doc = build_parameters_documentation(schema)

    if params_doc do
      "#{header}\n\n#{params_doc}"
    else
      header
    end
  end

  defp build_parameters_documentation(%{properties: properties, required: required})
       when is_map(properties) do
    # Build documentation for each parameter
    param_docs =
      Enum.map(properties, fn {field_name, field_spec} ->
        build_field_documentation(field_name, field_spec, required || [])
      end)

    "**Parameters:**\n" <> Enum.join(param_docs, "\n")
  end

  defp build_parameters_documentation(_schema), do: nil

  defp build_field_documentation(field_name, field_spec, required_fields) do
    is_required = field_name in required_fields
    type = field_spec[:type] || "any"
    description = field_spec[:description] || ""

    # Build constraint information
    constraints = build_constraints_documentation(field_spec)

    required_marker = if is_required, do: " (required)", else: " (optional)"

    base = "- `#{field_name}` (#{type})#{required_marker}: #{description}"

    if constraints != "" do
      "#{base} #{constraints}"
    else
      base
    end
  end

  defp build_constraints_documentation(field_spec) do
    constraints = []

    # Enum constraint
    constraints =
      if enum = field_spec[:enum] do
        constraints ++ ["allowed values: #{inspect(enum)}"]
      else
        constraints
      end

    # Numeric constraints
    constraints =
      if min = field_spec[:minimum] do
        constraints ++ ["min: #{min}"]
      else
        constraints
      end

    constraints =
      if max = field_spec[:maximum] do
        constraints ++ ["max: #{max}"]
      else
        constraints
      end

    # String constraints
    constraints =
      if min_length = field_spec[:minLength] do
        constraints ++ ["min length: #{min_length}"]
      else
        constraints
      end

    constraints =
      if max_length = field_spec[:maxLength] do
        constraints ++ ["max length: #{max_length}"]
      else
        constraints
      end

    constraints =
      if pattern = field_spec[:pattern] do
        constraints ++ ["pattern: #{pattern}"]
      else
        constraints
      end

    constraints =
      if format = field_spec[:format] do
        constraints ++ ["format: #{format}"]
      else
        constraints
      end

    # Array constraints
    constraints =
      if min_items = field_spec[:minItems] do
        constraints ++ ["min items: #{min_items}"]
      else
        constraints
      end

    constraints =
      if max_items = field_spec[:maxItems] do
        constraints ++ ["max items: #{max_items}"]
      else
        constraints
      end

    if length(constraints) > 0 do
      "[#{Enum.join(constraints, ", ")}]"
    else
      ""
    end
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
