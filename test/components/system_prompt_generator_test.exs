defmodule NormandyTest.Components.SystemPromptGeneratorTest do
  use ExUnit.Case, async: true
  doctest Normandy.Components.SystemPromptGenerator

  alias Normandy.Components.SystemPromptGenerator
  alias Normandy.Components.PromptSpecification
  alias NormandyTest.Support.ContextProvider

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

  test "context providers" do
    context_a = %ContextProvider{title: "title a", some_stuff: "some stuff"}
    context_b = %ContextProvider{title: "title b", some_stuff: "some other stuff"}

    spec = %PromptSpecification{
      background: ["you are a helpful assistant", "you assist me in assisting"],
      steps: ["step 1", "step 2", "step 3"],
      output_instructions: ["print the result", "as a result"],
      context_providers: %{
        "context_a" => context_a,
        "context_b" => context_b
      }
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
    # EXTRA INFORMATION AND CONTEXT
    ## title a
    some stuff
    ## title b
    some other stuff
    """

    result = SystemPromptGenerator.generate_prompt(spec)
    assert String.trim(prompt) == result
  end
end
