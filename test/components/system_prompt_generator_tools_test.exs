defmodule NormandyTest.Components.SystemPromptGeneratorToolsTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.{PromptSpecification, SystemPromptGenerator}
  alias Normandy.Tools.{Registry, Examples.Calculator, Examples.StringManipulator}

  describe "SystemPromptGenerator with tools" do
    test "generates prompt without tools when registry is nil" do
      spec = %PromptSpecification{
        background: ["You are a helpful assistant"],
        steps: ["Step 1", "Step 2"],
        output_instructions: ["Be concise"]
      }

      prompt = SystemPromptGenerator.generate_prompt(spec, nil)

      refute prompt =~ "AVAILABLE TOOLS"
      assert prompt =~ "IDENTITY and PURPOSE"
    end

    test "generates prompt without tools when registry is empty" do
      spec = %PromptSpecification{
        background: ["You are a helpful assistant"],
        steps: [],
        output_instructions: []
      }

      registry = Registry.new()
      prompt = SystemPromptGenerator.generate_prompt(spec, registry)

      refute prompt =~ "AVAILABLE TOOLS"
    end

    test "includes tool information when tools are available" do
      spec = %PromptSpecification{
        background: ["You are a helpful assistant"],
        steps: [],
        output_instructions: []
      }

      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      prompt = SystemPromptGenerator.generate_prompt(spec, registry)

      assert prompt =~ "AVAILABLE TOOLS"
      assert prompt =~ "You have access to the following tools:"
      assert prompt =~ "calculator"
      assert prompt =~ "arithmetic"
    end

    test "includes multiple tools in prompt" do
      spec = %PromptSpecification{
        background: ["You are a helpful assistant"],
        steps: [],
        output_instructions: []
      }

      calc = %Calculator{operation: "add", a: 0, b: 0}
      string = %StringManipulator{operation: "uppercase", text: ""}

      registry = Registry.new([calc, string])
      prompt = SystemPromptGenerator.generate_prompt(spec, registry)

      assert prompt =~ "AVAILABLE TOOLS"
      assert prompt =~ "calculator"
      assert prompt =~ "string_manipulator"
      assert prompt =~ "arithmetic"
      assert prompt =~ "string manipulation"
    end

    test "tool section appears after other sections" do
      spec = %PromptSpecification{
        background: ["You are a helpful assistant"],
        steps: ["Think carefully"],
        output_instructions: ["Be precise"]
      }

      calc = %Calculator{operation: "add", a: 0, b: 0}
      registry = Registry.new([calc])

      prompt = SystemPromptGenerator.generate_prompt(spec, registry)

      # Ensure tools come after main sections
      identity_pos = :binary.match(prompt, "IDENTITY and PURPOSE") |> elem(0)
      steps_pos = :binary.match(prompt, "INTERNAL ASSISTANT STEPS") |> elem(0)
      output_pos = :binary.match(prompt, "OUTPUT INSTRUCTIONS") |> elem(0)
      tools_pos = :binary.match(prompt, "AVAILABLE TOOLS") |> elem(0)

      assert identity_pos < steps_pos
      assert steps_pos < output_pos
      assert output_pos < tools_pos
    end
  end
end
