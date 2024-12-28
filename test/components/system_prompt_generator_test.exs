defmodule Components.SystemPromptGeneratorTest do
  use ExUnit.Case, async: true
  doctest Normandy.Components.SystemPromptGenerator

  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Components.PromptSpecification

  test "with empty specification" do
    prompt = """
    # IDENTITY and PURPOSE
    - This is a conversation with a helpful and friendly AI assistant.
    # OUTPUT INSTRUCTIONS
    - Always respond using the proper JSON schema.
    - Always use the available additional information and context to enhance the response.
    """

    spec = %PromptSpecification{}

    result = SystemPromptGenerator.generate_prompt(spec)

    assert String.trim(prompt) == result
  end

  test "write a specification" do
    spec = %PromptSpecification{
      background: ["you are a helpful assistant", "you assist me in assisting"],
      steps: ["step 1", "step 2", "step 3"],
      output_instructions: ["print the result", "as a result"]
    }

    prompt = """
    # IDENTITY and PURPOSE
    - you are a helpful assistant
    - you assist me in assisting
    # INTERNAL ASSISTANT STEPS
    - step 1
    - step 2
    - step 3
    # OUTPUT INSTRUCTIONS
    - print the result
    - as a result
    - Always respond using the proper JSON schema.
    - Always use the available additional information and context to enhance the response.
    """

    result = SystemPromptGenerator.generate_prompt(spec)
    assert String.trim(prompt) == result
  end
end
