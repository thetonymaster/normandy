# Normandy

A powerful Elixir library for building AI agents with structured schemas, memory management, and tool calling capabilities.

## Features

- 🧠 **Agent System** - Build conversational AI agents with memory and state management
- 📋 **Schema DSL** - Define typed, validated data structures with ease
- 🔧 **Tool Calling** - Integrate LLM tool calling with automatic execution loops
- 💾 **Memory Management** - Track conversation history with turn-based organization
- ✅ **Validation** - Changeset-style validation similar to Ecto
- 🎯 **Type Safety** - Comprehensive type system with Dialyzer support
- 🧪 **Well Tested** - 227+ tests including property-based testing

## Installation

Add `normandy` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:normandy, "~> 0.1.0"}
  ]
end
```

## Quick Start

### Defining Schemas

```elixir
defmodule User do
  use Normandy.Schema

  schema do
    field(:name, :string, required: true)
    field(:age, :integer, default: 0)
    field(:email, :string, required: true)
  end
end

user = %User{name: "Alice", email: "alice@example.com"}
```

### Creating an Agent

```elixir
# Define your LLM client (implement Normandy.Agents.Model protocol)
defmodule MyLLMClient do
  use Normandy.Schema

  schema do
    field(:api_key, :string)
  end

  defimpl Normandy.Agents.Model do
    def converse(client, model, temperature, max_tokens, messages, response_schema, opts \\ []) do
      # Your LLM API call here
      # Return structured response matching response_schema
    end
  end
end

# Initialize an agent
config = %{
  client: %MyLLMClient{api_key: "..."},
  model: "gpt-4",
  temperature: 0.7
}

agent = Normandy.Agents.BaseAgent.init(config)

# Run a conversation
{updated_agent, response} = Normandy.Agents.BaseAgent.run(agent, %{chat_message: "Hello!"})
```

### Using Tools

```elixir
# Define a tool
defmodule CalculatorTool do
  defstruct [:operation, :a, :b]

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_), do: "calculator"

    def tool_description(_) do
      "Performs basic arithmetic operations"
    end

    def input_schema(_) do
      %{
        type: "object",
        properties: %{
          operation: %{type: "string", enum: ["add", "subtract", "multiply", "divide"]},
          a: %{type: "number"},
          b: %{type: "number"}
        },
        required: ["operation", "a", "b"]
      }
    end

    def run(%{operation: "add", a: a, b: b}), do: {:ok, a + b}
    def run(%{operation: "subtract", a: a, b: b}), do: {:ok, a - b}
    def run(%{operation: "multiply", a: a, b: b}), do: {:ok, a * b}
    def run(%{operation: "divide", a: _a, b: 0}), do: {:error, "Cannot divide by zero"}
    def run(%{operation: "divide", a: a, b: b}), do: {:ok, a / b}
  end
end

# Register tools with agent
calc = %CalculatorTool{operation: "add", a: 0, b: 0}
agent = Normandy.Agents.BaseAgent.register_tool(agent, calc)

# Run with tool calling enabled
{updated_agent, response} = Normandy.Agents.BaseAgent.run_with_tools(
  agent,
  %{chat_message: "What is 15 + 27?"}
)
```

### Memory Management

```elixir
# Access conversation history
history = Normandy.Components.AgentMemory.history(agent.memory)

# Reset memory to initial state
agent = Normandy.Agents.BaseAgent.reset_memory(agent)

# Save and load memory
dump = Normandy.Components.AgentMemory.dump(agent.memory)
loaded_memory = Normandy.Components.AgentMemory.load(dump)
```

### Validation

```elixir
defmodule UserInput do
  use Normandy.Schema

  schema do
    field(:name, :string)
    field(:age, :integer)
    field(:email, :string)
  end
end

# Validate input
changeset = Normandy.Validate.cast(%UserInput{}, params, [:name, :age, :email])
  |> Normandy.Validate.validate_required([:name, :email])
  |> Normandy.Validate.validate_format(:email, ~r/@/)
  |> Normandy.Validate.validate_number(:age, greater_than_or_equal_to: 0)

if changeset.valid? do
  user = Normandy.Validate.apply_changes(changeset)
else
  errors = changeset.errors
end
```

## Architecture

### Core Components

- **Normandy.Schema** - Macro-based DSL for defining structured data
- **Normandy.Type** - Type system with casting and validation
- **Normandy.Validate** - Changeset-style validation

### Agent System

- **Normandy.Agents.BaseAgent** - Core agent implementation
- **Normandy.Components.AgentMemory** - Conversation memory management
- **Normandy.Components.Message** - Message structure for conversations
- **Normandy.Components.SystemPromptGenerator** - Dynamic prompt generation

### Tool System

- **Normandy.Tools.BaseTool** - Protocol for defining tools
- **Normandy.Tools.Registry** - Manages tool collections
- **Normandy.Tools.Executor** - Safe tool execution with timeout/retry
- **Normandy.Tools.Examples** - Example tools (Calculator, StringManipulator, ListProcessor)

## Testing

Run the test suite:

```bash
mix test
```

Run with coverage:

```bash
mix test --cover
```

Run Dialyzer for type checking:

```bash
mix dialyzer
```

## Example Tools

Normandy includes several example tools to demonstrate the tool system:

- **Calculator** - Basic arithmetic operations
- **StringManipulator** - Text operations (uppercase, lowercase, reverse, split, etc.)
- **ListProcessor** - List operations (sum, average, min, max, sort)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

[Add your license here]

## Documentation

Full documentation can be generated with:

```bash
mix docs
```

Then open `doc/index.html` in your browser.
