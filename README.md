# Normandy

A powerful Elixir library for building AI agents with structured schemas, memory management, and tool calling capabilities.

## Features

- 🧠 **Agent System** - Build conversational AI agents with memory and state management
- 📋 **Schema DSL** - Define typed, validated data structures with ease
- 🔧 **Tool Calling** - Integrate LLM tool calling with automatic execution loops
- 🌊 **Streaming** - Real-time response streaming with callback-based event processing
- 🔄 **Resilience** - Built-in retry and circuit breaker patterns for production reliability
- 💾 **Memory Management** - Track conversation history with turn-based organization
- ✅ **Validation** - Changeset-style validation similar to Ecto
- 🎯 **Type Safety** - Comprehensive type system with Dialyzer support
- 🧪 **Well Tested** - 295+ tests including property-based testing

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

### Creating an Agent with Claudio (Recommended)

Normandy includes a ready-to-use adapter for [Claudio](https://github.com/anthropics/claudio), the official Anthropic API client:

```elixir
# Use the built-in Claudio adapter
client = %Normandy.LLM.ClaudioAdapter{
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  options: %{
    timeout: 60_000,
    enable_caching: true  # 90% cost reduction on repeated prompts!
  }
}

# Initialize an agent
config = %{
  client: client,
  model: "claude-3-5-sonnet-20241022",
  temperature: 0.7
}

agent = Normandy.Agents.BaseAgent.init(config)

# Run a conversation
{updated_agent, response} = Normandy.Agents.BaseAgent.run(agent, %{chat_message: "Hello!"})
```

### Creating a Custom Agent

You can also implement the `Normandy.Agents.Model` protocol for any LLM provider:

```elixir
defmodule MyLLMClient do
  use Normandy.Schema

  schema do
    field(:api_key, :string)
  end

  defimpl Normandy.Agents.Model do
    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model) do
      # Legacy API - return response_model
      response_model
    end

    def converse(client, model, temperature, max_tokens, messages, response_schema, opts \\ []) do
      # Your LLM API call here
      # Return structured response matching response_schema
    end
  end
end

# Initialize an agent
config = %{
  client: %MyLLMClient{api_key: "..."},
  model: "your-model",
  temperature: 0.7
}

agent = Normandy.Agents.BaseAgent.init(config)
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

### Streaming Responses

Normandy supports real-time streaming of LLM responses with callbacks for processing events as they arrive:

```elixir
# Stream a response with real-time processing
callback = fn
  :text_delta, text ->
    IO.write(text)  # Display text as it arrives

  :tool_use_start, tool ->
    IO.puts("\nCalling tool: #{tool["name"]}")

  :message_start, message ->
    IO.puts("Starting response from #{message["model"]}")

  :message_stop, _ ->
    IO.puts("\nResponse complete")

  _, _ ->
    :ok  # Ignore other events
end

{updated_agent, response} = Normandy.Agents.BaseAgent.stream_response(
  agent,
  %{chat_message: "Hello!"},
  callback
)

# Stream with tool calling support
{updated_agent, response} = Normandy.Agents.BaseAgent.stream_with_tools(
  agent,
  %{chat_message: "What is 15 + 27?"},
  callback
)
```

#### Streaming Event Types

- `:text_delta` - Incremental text content as it's generated
- `:tool_use_start` - Tool call beginning with tool metadata
- `:tool_result` - Tool execution result (custom event in stream_with_tools)
- `:thinking_delta` - Extended thinking content (if enabled)
- `:message_start` - Stream beginning with message metadata
- `:message_stop` - Stream complete

#### Implementing Streaming for Custom Clients

To add streaming support to a custom LLM client, implement the `stream_converse/7` function in your Model protocol implementation:

```elixir
defimpl Normandy.Agents.Model do
  def converse(client, model, temperature, max_tokens, messages, response_schema, opts \\ []) do
    # Non-streaming implementation
  end

  def stream_converse(client, model, temperature, max_tokens, messages, _response_model, opts \\ []) do
    callback = Keyword.get(opts, :callback)

    # Return a stream of Server-Sent Events
    {:ok, stream} = your_llm_client.stream(...)

    # Parse events and invoke callback for each
    event_stream = Stream.map(stream, fn event ->
      # Invoke callback based on event type
      case event do
        %{type: "content_block_delta", delta: %{"type" => "text_delta", "text" => text}} ->
          if callback, do: callback.(:text_delta, text)
        %{type: "message_start", message: message} ->
          if callback, do: callback.(:message_start, message)
        _ -> :ok
      end

      event
    end)

    {:ok, event_stream}
  end
end
```

### Resilience & Error Handling

Normandy includes built-in resilience patterns to handle transient failures and prevent cascading errors in production systems.

#### Retry Mechanism

Automatically retry failed LLM calls with exponential backoff and jitter:

```elixir
# Use a preset retry configuration
agent = Normandy.Agents.BaseAgent.init(%{
  client: client,
  model: "claude-3-5-sonnet-20241022",
  temperature: 0.7,
  retry_options: Normandy.Resilience.Retry.preset(:standard)
})

# Custom retry configuration
agent = Normandy.Agents.BaseAgent.init(%{
  client: client,
  model: "claude-3-5-sonnet-20241022",
  temperature: 0.7,
  retry_options: [
    max_attempts: 5,
    base_delay: 1000,      # 1 second
    max_delay: 30_000,     # 30 seconds
    backoff_factor: 2.0,   # Exponential backoff
    jitter: true           # Add randomness to delays
  ]
})

# Now agent calls will automatically retry on transient failures
{updated_agent, response} = Normandy.Agents.BaseAgent.run(agent, %{chat_message: "Hello!"})
```

**Available Retry Presets:**

- `:quick` - Fast retries (2 attempts, 100ms base delay)
- `:standard` - Default config (3 attempts, 1s base delay)
- `:persistent` - Aggressive retries (5 attempts, 1s base delay)
- `:patient` - Long-running retries (10 attempts, 2s base delay)

**Retry Features:**

- Exponential backoff with configurable factor
- Jitter to prevent thundering herd
- Automatic retry on network errors, timeouts, rate limits
- Custom retry conditions via `:retry_if` function
- Detailed error tracking across attempts

#### Circuit Breaker

Prevent cascading failures by failing fast when a threshold is reached:

```elixir
# Enable circuit breaker with defaults
agent = Normandy.Agents.BaseAgent.init(%{
  client: client,
  model: "claude-3-5-sonnet-20241022",
  temperature: 0.7,
  enable_circuit_breaker: true
})

# Custom circuit breaker configuration
agent = Normandy.Agents.BaseAgent.init(%{
  client: client,
  model: "claude-3-5-sonnet-20241022",
  temperature: 0.7,
  enable_circuit_breaker: true,
  circuit_breaker_options: [
    failure_threshold: 5,      # Open after 5 failures
    success_threshold: 2,      # Close after 2 successes in half-open
    timeout: 60_000,           # Try half-open after 60 seconds
    half_open_max_calls: 1     # Allow 1 test call in half-open state
  ]
})

# Circuit breaker will automatically manage state
{updated_agent, response} = Normandy.Agents.BaseAgent.run(agent, %{chat_message: "Hello!"})
```

**Circuit Breaker States:**

- **Closed** - Normal operation, requests pass through
- **Open** - Threshold exceeded, requests fail fast without calling LLM
- **Half-Open** - Testing recovery, limited requests allowed

**State Transitions:**

```
Closed ──(failures > threshold)──> Open
  ↑                                   │
  │                                   │
  └──(success)── Half-Open ←─(timeout)┘
```

#### Combining Retry and Circuit Breaker

Both patterns work together for comprehensive protection:

```elixir
agent = Normandy.Agents.BaseAgent.init(%{
  client: client,
  model: "claude-3-5-sonnet-20241022",
  temperature: 0.7,
  # Retry handles transient errors
  retry_options: [
    max_attempts: 3,
    base_delay: 1000
  ],
  # Circuit breaker prevents cascading failures
  enable_circuit_breaker: true,
  circuit_breaker_options: [
    failure_threshold: 5,
    timeout: 60_000
  ]
})
```

**How They Work Together:**

1. **Retry** wraps the LLM call and attempts to recover from transient failures
2. **Circuit Breaker** wraps the retry logic and sees the aggregate result
3. Transient errors are handled by retry without affecting circuit breaker
4. Persistent failures eventually open the circuit to prevent cascading issues

#### Using Retry Directly

You can also use the retry mechanism for any function:

```elixir
alias Normandy.Resilience.Retry

# Basic retry
{:ok, result} = Retry.with_retry(fn ->
  {:ok, perform_risky_operation()}
end)

# With custom configuration
{:ok, result} = Retry.with_retry(
  fn -> {:ok, api_call()} end,
  max_attempts: 5,
  base_delay: 500,
  retry_if: fn
    {:error, %{status: status}} when status >= 500 -> true
    {:error, :network_error} -> true
    _ -> false
  end
)

# Using presets
Retry.with_retry(fn -> {:ok, slow_operation()} end, Retry.preset(:patient))
```

#### Using Circuit Breaker Directly

You can also use circuit breaker as a standalone GenServer:

```elixir
alias Normandy.Resilience.CircuitBreaker

# Start a circuit breaker
{:ok, cb} = CircuitBreaker.start_link(
  name: :api_breaker,
  failure_threshold: 5,
  timeout: 60_000
)

# Execute protected calls
case CircuitBreaker.call(cb, fn ->
  {:ok, MyAPI.risky_operation()}
end) do
  {:ok, result} -> handle_success(result)
  {:error, :open} -> handle_circuit_open()
  {:error, reason} -> handle_failure(reason)
end

# Check state
CircuitBreaker.state(cb)  #=> :closed | :open | :half_open

# Get metrics
CircuitBreaker.metrics(cb)
#=> %{
  state: :closed,
  failure_count: 2,
  success_count: 100,
  opened_at: nil
}

# Manual control
CircuitBreaker.reset(cb)  # Force close
CircuitBreaker.trip(cb)   # Force open
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

- **Normandy.Agents.BaseAgent** - Core agent implementation with streaming support
- **Normandy.Components.AgentMemory** - Conversation memory management
- **Normandy.Components.Message** - Message structure for conversations
- **Normandy.Components.SystemPromptGenerator** - Dynamic prompt generation

### Streaming System

- **Normandy.Components.StreamEvent** - Server-Sent Event schema
- **Normandy.Components.StreamProcessor** - Stream processing utilities
- **Normandy.LLM.ClaudioAdapter** - Built-in Claudio adapter with streaming

### Resilience System

- **Normandy.Resilience.Retry** - Exponential backoff retry with jitter
- **Normandy.Resilience.CircuitBreaker** - Three-state circuit breaker pattern

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
