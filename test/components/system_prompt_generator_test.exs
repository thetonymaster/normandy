defmodule NormandyTest.Components.SystemPromptGeneratorTest do
  use ExUnit.Case, async: true
  doctest Normandy.Components.SystemPromptGenerator

  alias Normandy.Components.PromptSpecification
  alias Normandy.Components.SystemPromptGenerator
  alias NormandyTest.Support.ContextProvider

  test "with empty specification" do
    prompt = """
    # Role
    You are a helpful assistant.
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
    # Role
    you are a helpful assistant
    you assist me in assisting
    # How to work
    - step 1
    - step 2
    - step 3
    # Output
    - print the result
    - as a result
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
    # Role
    you are a helpful assistant
    you assist me in assisting
    # How to work
    - step 1
    - step 2
    - step 3
    # Output
    - print the result
    - as a result
    # Context
    Use this information where it is relevant to the request.
    ## title a
    some stuff
    ## title b
    some other stuff
    """

    result = SystemPromptGenerator.generate_prompt(spec)
    assert String.trim(prompt) == result
  end

  test "generate_prompt/2 no longer exists (tools go through the API tools parameter)" do
    # function_exported?/3 is false for a module that isn't loaded yet (mix test
    # loads lazily), which would make this pass before the change.
    Code.ensure_loaded!(SystemPromptGenerator)
    refute function_exported?(SystemPromptGenerator, :generate_prompt, 2)
  end

  test "no context line without context providers" do
    result = SystemPromptGenerator.generate_prompt(%PromptSpecification{})
    refute result =~ "# Context"
    refute result =~ "Use this information"
  end
end
