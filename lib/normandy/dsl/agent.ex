defmodule Normandy.DSL.Agent do
  @moduledoc """
  DSL for defining AI agents with a clean, declarative syntax.

  Provides macros to simplify agent creation with sensible defaults and
  expressive configuration options.

  ## Examples

      defmodule MyResearchAgent do
        use Normandy.DSL.Agent

        agent do
          name "Research Agent"
          description "Conducts research and analysis"

          model "claude-3-5-sonnet-20241022"
          temperature 0.7
          max_tokens 4096

          system_prompt \"\"\"
          You are a helpful research assistant.
          Provide thorough, well-researched answers.
          \"\"\"

          # Optional: Define tools
          tool CalculatorTool
          tool SearchTool
        end
      end

      # Create an instance
      {:ok, agent} = MyResearchAgent.new(client: my_client)

      # Run the agent
      {updated_agent, response} = MyResearchAgent.run(agent, "Research quantum computing")

  ## Without DSL (for comparison)

      config = %{
        client: my_client,
        model: "claude-3-5-sonnet-20241022",
        temperature: 0.7,
        max_tokens: 4096
      }

      agent = Normandy.Agents.BaseAgent.init(config)
      # ... configure system prompt, tools, etc.

  ## Features

  - Clean, declarative syntax
  - Sensible defaults
  - Compile-time validation
  - Generated helper functions
  - Tool registration support
  - Memory management helpers
  """

  alias Normandy.Agents.BaseAgent
  alias Normandy.Components.PromptSpecification

  defmacro __using__(_opts) do
    quote do
      import Normandy.DSL.Agent
      Module.register_attribute(__MODULE__, :agent_config, accumulate: false)
      Module.register_attribute(__MODULE__, :agent_tools, accumulate: true)
      @before_compile Normandy.DSL.Agent
    end
  end

  @doc """
  Defines an agent configuration block.

  ## Available Options

  - `name` - Agent name (optional)
  - `description` - Agent description (optional)
  - `model` - LLM model to use (required)
  - `temperature` - Sampling temperature 0.0-1.0 (default: 0.7)
  - `max_tokens` - Maximum tokens in response (default: 4096)
  - `system_prompt` - System prompt text (optional)
  - `background` - Background context for prompt (optional)
  - `steps` - Internal reasoning steps (optional)
  - `output_instructions` - Output formatting instructions (optional)
  - `tool` - Register a tool module (can be called multiple times)
  - `max_messages` - Maximum messages in memory (optional)

  ## Examples

      agent do
        name "My Agent"
        model "claude-3-5-sonnet-20241022"
        temperature 0.8

        system_prompt "You are helpful."
      end
  """
  defmacro agent(do: block) do
    quote do
      unquote(block)
    end
  end

  @doc """
  Sets the agent name.
  """
  defmacro name(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_name, unquote(value))
    end
  end

  @doc """
  Sets the agent description.
  """
  defmacro description(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_description, unquote(value))
    end
  end

  @doc """
  Sets the LLM model.
  """
  defmacro model(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_model, unquote(value))
    end
  end

  @doc """
  Sets the temperature.
  """
  defmacro temperature(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_temperature, unquote(value))
    end
  end

  @doc """
  Sets the max tokens.
  """
  defmacro max_tokens(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_max_tokens, unquote(value))
    end
  end

  @doc """
  Sets the system prompt.
  """
  defmacro system_prompt(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_system_prompt, unquote(value))
    end
  end

  @doc """
  Sets the background context.
  """
  defmacro background(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_background, unquote(value))
    end
  end

  @doc """
  Sets the internal steps.
  """
  defmacro steps(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_steps, unquote(value))
    end
  end

  @doc """
  Sets the output instructions.
  """
  defmacro output_instructions(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_output_instructions, unquote(value))
    end
  end

  @doc """
  Registers a tool module.
  """
  defmacro tool(module) do
    quote do
      Module.put_attribute(__MODULE__, :agent_tools, unquote(module))
    end
  end

  @doc """
  Sets the maximum number of messages in memory.
  """
  defmacro max_messages(value) do
    quote do
      Module.put_attribute(__MODULE__, :agent_max_messages, unquote(value))
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      # Store configuration at compile time - MUST come first before any function uses it
      @agent_compile_config %{
        model: Module.get_attribute(__MODULE__, :agent_model),
        temperature: Module.get_attribute(__MODULE__, :agent_temperature, 0.7),
        max_tokens: Module.get_attribute(__MODULE__, :agent_max_tokens, 4096),
        max_messages: Module.get_attribute(__MODULE__, :agent_max_messages),
        system_prompt: Module.get_attribute(__MODULE__, :agent_system_prompt),
        background: Module.get_attribute(__MODULE__, :agent_background),
        steps: Module.get_attribute(__MODULE__, :agent_steps),
        output_instructions: Module.get_attribute(__MODULE__, :agent_output_instructions),
        tools: Module.get_attribute(__MODULE__, :agent_tools, []) |> Enum.reverse()
      }

      # Store additional config at compile time
      @agent_name Module.get_attribute(__MODULE__, :agent_name)
      @agent_description Module.get_attribute(__MODULE__, :agent_description)

      @doc """
      Creates a new agent instance.

      ## Options

      - `:client` - LLM client (required)
      - `:override` - Keyword list to override agent defaults

      ## Examples

          {:ok, agent} = MyAgent.new(client: my_client)

          # With overrides
          {:ok, agent} = MyAgent.new(
            client: my_client,
            override: [temperature: 0.9]
          )
      """
      def new(opts) do
        client = Keyword.fetch!(opts, :client)
        overrides = Keyword.get(opts, :override, [])

        config = build_config(client, overrides)
        agent = BaseAgent.init(config)

        # Apply system prompt if defined
        agent = apply_system_prompt(agent)

        # Register tools if any
        agent = register_tools(agent)

        {:ok, agent}
      end

      @doc """
      Runs the agent with input.

      ## Examples

          {updated_agent, response} = MyAgent.run(agent, "Hello!")
          {updated_agent, response} = MyAgent.run(agent, %{chat_message: "Hello!"})
      """
      def run(agent, input) do
        BaseAgent.run(agent, prepare_input(input))
      end

      @doc """
      Runs the agent with tools enabled.

      ## Examples

          {updated_agent, response} = MyAgent.run_with_tools(agent, "Calculate 2+2")
      """
      def run_with_tools(agent, input) do
        BaseAgent.run_with_tools(agent, prepare_input(input))
      end

      @doc """
      Resets the agent's memory.

      ## Examples

          agent = MyAgent.reset_memory(agent)
      """
      def reset_memory(agent) do
        BaseAgent.reset_memory(agent)
      end

      @doc """
      Returns the agent configuration used by this module.
      """
      def config do
        %{
          name: @agent_name,
          description: @agent_description,
          model: @agent_compile_config.model,
          temperature: @agent_compile_config.temperature,
          max_tokens: @agent_compile_config.max_tokens,
          system_prompt: @agent_compile_config.system_prompt,
          background: @agent_compile_config.background,
          steps: @agent_compile_config.steps,
          output_instructions: @agent_compile_config.output_instructions,
          tools: @agent_compile_config.tools,
          max_messages: @agent_compile_config.max_messages
        }
      end

      # Private functions

      defp build_config(client, overrides) do
        unless @agent_compile_config.model do
          raise "model is required in agent definition"
        end

        base_config = %{
          client: client,
          model: @agent_compile_config.model,
          temperature: @agent_compile_config.temperature,
          max_tokens: @agent_compile_config.max_tokens
        }

        # Apply max_messages if set
        base_config =
          if @agent_compile_config.max_messages do
            Map.put(base_config, :max_messages, @agent_compile_config.max_messages)
          else
            base_config
          end

        # Apply overrides
        Enum.reduce(overrides, base_config, fn {key, value}, acc ->
          Map.put(acc, key, value)
        end)
      end

      defp apply_system_prompt(agent) do
        cond do
          @agent_compile_config.system_prompt != nil ->
            # Simple system prompt - convert string to list
            prompt_spec = %PromptSpecification{
              background: to_list(@agent_compile_config.system_prompt),
              steps: [],
              output_instructions: []
            }

            %{agent | prompt_specification: prompt_spec}

          @agent_compile_config.background != nil or
            @agent_compile_config.steps != nil or
              @agent_compile_config.output_instructions != nil ->
            # Structured prompt - convert strings to lists
            prompt_spec = %PromptSpecification{
              background: to_list(@agent_compile_config.background),
              steps: to_list(@agent_compile_config.steps),
              output_instructions: to_list(@agent_compile_config.output_instructions)
            }

            %{agent | prompt_specification: prompt_spec}

          true ->
            agent
        end
      end

      defp to_list(nil), do: []
      defp to_list(str) when is_binary(str), do: [str]
      defp to_list(list) when is_list(list), do: list

      defp register_tools(agent) do
        Enum.reduce(@agent_compile_config.tools, agent, fn tool_module, acc ->
          tool = struct(tool_module)
          BaseAgent.register_tool(acc, tool)
        end)
      end

      defp prepare_input(input) when is_binary(input), do: %{chat_message: input}
      defp prepare_input(input) when is_map(input), do: input
      defp prepare_input(input), do: %{chat_message: to_string(input)}
    end
  end
end
