# Normandy

A powerful Elixir library for building AI agents with structured schemas, memory management, and tool calling capabilities.

## Features

- 🧠 **Agent System** - Build conversational AI agents with memory and state management
- 🤝 **Multi-Agent Coordination** - Reactive patterns (race/all/some) and agent pooling for concurrent workflows
- 📋 **Schema DSL** - Define typed, validated data structures with JSON Schema generation
  - Virtual/computed fields with custom transformations
  - Composition (anyOf, oneOf, allOf) for polymorphic types
  - Conditional schemas (if/then/else) for context-dependent validation
  - Runtime validation with comprehensive constraint checking
  - Schema introspection for metadata queries
- 🔧 **Tool Calling** - Integrate LLM tool calling with automatic execution loops
- 🌊 **Streaming** - Real-time response streaming with callback-based event processing
- 💰 **Prompt Caching** - Up to 90% cost reduction with automatic caching support
- 🔄 **Resilience** - Built-in retry and circuit breaker patterns for production reliability
- 📦 **Batch Processing** - Concurrent processing of multiple inputs with progress tracking
- 📏 **Context Management** - Token counting, automatic truncation, and conversation summarization
- 💾 **Memory Management** - Track conversation history with turn-based organization
- ✅ **Validation** - Runtime data validation with format checking (email, UUID, etc.)
- 🎯 **Type Safety** - Comprehensive type system with Dialyzer support
- 🧪 **Well Tested** - 490+ tests including property-based testing

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

### Nested Schemas

Normandy supports nested schemas with full JSON Schema generation:

```elixir
defmodule Address do
  use Normandy.Schema

  io_schema "Address information" do
    field(:street, :string, description: "Street address", required: true)
    field(:city, :string, description: "City name", required: true)
    field(:postal_code, :string, description: "Postal code", pattern: "^[0-9]{5}$")
  end
end

defmodule User do
  use Normandy.Schema

  io_schema "User profile" do
    field(:name, :string, description: "Full name", required: true)
    field(:age, :integer, description: "Age", minimum: 0, maximum: 150)
    # Single nested schema
    field(:address, Address, description: "Primary address", required: true)
    # Array of nested schemas
    field(:previous_addresses, {:array, Address}, description: "Previous addresses")
  end
end

# Create instances
user = %User{
  name: "Alice",
  age: 30,
  address: %Address{street: "123 Main St", city: "Portland"},
  previous_addresses: [
    %Address{street: "456 Oak Ave", city: "Seattle"}
  ]
}

# Export as JSON Schema for LLM prompts
schema = User.get_json_schema()
# Nested schemas are inlined with all constraints preserved
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

### Prompt Caching

Normandy supports Anthropic's prompt caching feature, which can reduce costs by up to 90% for repeated prompts. When caching is enabled, system prompts and tool definitions are automatically cached.

```elixir
# Enable caching in the Claudio adapter
client = %Normandy.LLM.ClaudioAdapter{
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  options: %{
    enable_caching: true  # Enable prompt caching
  }
}

agent = Normandy.Agents.BaseAgent.init(%{
  client: client,
  model: "claude-3-5-sonnet-20241022",
  temperature: 0.7
})

# System prompts and tools are now automatically cached
{updated_agent, response} = Normandy.Agents.BaseAgent.run(agent, %{chat_message: "Hello!"})
```

**What Gets Cached:**
- **System prompts** - Automatically cached using `set_system_with_cache`
- **Tool definitions** - Last tool in list is cached using `add_tool_with_cache`
- Cache is ephemeral with ~5 minute TTL on inactivity

**Cache Benefits:**
- Up to 90% cost reduction on cached content
- Faster response times for repeated contexts
- Automatic cache management by Anthropic API

**When to Use Caching:**
- Long system prompts that remain constant
- Multiple requests with same tool definitions
- Repeated conversations with consistent context
- Batch processing with shared instructions

**Note:** Caching requires minimum content length (1024 tokens for system prompts). Shorter content won't benefit from caching.

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

### Batch Processing

Process multiple inputs concurrently with configurable concurrency, progress tracking, and error handling:

```elixir
alias Normandy.Batch.Processor

# Simple batch processing
inputs = [
  %{chat_message: "Hello"},
  %{chat_message: "How are you?"},
  %{chat_message: "Goodbye"}
]

{:ok, results} = Processor.process_batch(agent, inputs)

# With concurrency control and progress tracking
{:ok, results} = Processor.process_batch(
  agent,
  inputs,
  max_concurrency: 5,
  on_progress: fn completed, total ->
    IO.puts("Progress: #{completed}/#{total}")
  end
)

# Get detailed statistics
{:ok, stats} = Processor.process_batch_with_stats(agent, inputs)
#=> %{
  success: [result1, result2],
  errors: [{error1, input1}],
  total: 3,
  success_count: 2,
  error_count: 1
}

# Process large batches in chunks
{:ok, results} = Processor.process_batch_chunked(
  agent,
  large_input_list,
  chunk_size: 50,
  chunk_delay: 1000,  # 1 second between chunks
  max_concurrency: 5
)

# Error handling with callbacks
{:ok, results} = Processor.process_batch(
  agent,
  inputs,
  on_error: fn input, error ->
    Logger.error("Failed to process #{inspect(input)}: #{inspect(error)}")
  end
)
```

**Batch Processing Options:**

- `:max_concurrency` - Maximum concurrent tasks (default: 10)
- `:ordered` - Preserve input order in results (default: true)
- `:timeout` - Timeout per task in milliseconds (default: 300,000ms)
- `:on_progress` - Callback function: `(completed, total -> any)`
- `:on_error` - Callback function: `(input, error -> any)`
- `:chunk_size` - Items per chunk for chunked processing (default: 100)
- `:chunk_delay` - Delay between chunks in milliseconds (default: 0)

**Using Batch Processing with BaseAgent:**

```elixir
# Directly on agent
{:ok, results} = Normandy.Agents.BaseAgent.process_batch(agent, inputs)

# With statistics
{:ok, stats} = Normandy.Agents.BaseAgent.process_batch_with_stats(agent, inputs)
```

### Context Window Management

Normandy provides utilities for managing context window limits with automatic truncation to prevent token limit errors.

```elixir
alias Normandy.Context.WindowManager

# Create a window manager for a specific model
manager = WindowManager.for_model("claude-3-5-sonnet-20241022")

# Check if conversation is within limits
{:ok, within_limit?} = WindowManager.within_limit?(manager, agent)

# Automatically truncate if needed
{:ok, updated_agent} = WindowManager.ensure_within_limit(agent, manager)

# Estimate token usage
tokens = WindowManager.estimate_conversation_tokens(agent.memory)
IO.puts("Current conversation uses ~#{tokens} tokens")
```

**Token Estimation:**

```elixir
# Estimate tokens for text
tokens = WindowManager.estimate_tokens("Hello, world!")
#=> ~4 tokens (rough estimate: 1 token ≈ 4 characters)

# Estimate tokens for entire conversation
total = WindowManager.estimate_conversation_tokens(agent.memory)
```

**Truncation Strategies:**

```elixir
# Oldest-first strategy (default) - removes oldest messages
manager = WindowManager.new(
  max_tokens: 100_000,
  reserved_tokens: 4096,
  strategy: :oldest_first
)

# Sliding window - keeps most recent messages
manager = WindowManager.new(strategy: :sliding_window)

# Ensure conversation stays within limit
{:ok, updated_agent} = WindowManager.ensure_within_limit(agent, manager)
```

**Token Counting API:**

For accurate token counts, use the Anthropic API:

```elixir
alias Normandy.Context.TokenCounter

# Count tokens for a message
{:ok, count} = TokenCounter.count_message(client, "Hello, world!")
#=> {:ok, %{"input_tokens" => 4}}

# Count tokens for entire conversation
{:ok, count} = TokenCounter.count_conversation(client, agent)
#=> {:ok, %{"input_tokens" => 1234}}

# Get detailed breakdown
{:ok, details} = TokenCounter.count_detailed(client, agent)
#=> {:ok, %{
  total_tokens: 1234,
  system_tokens: 100,
  message_tokens: 1134,
  messages: [...]
}}
```

**Model Context Limits:**

```elixir
# Automatically configured for known models
manager = WindowManager.for_model("claude-3-5-sonnet-20241022")
#=> 200,000 token limit

# Supported models:
# - claude-3-5-sonnet-20241022: 200K tokens
# - claude-3-5-haiku-20241022: 200K tokens
# - claude-3-opus-20240229: 200K tokens
# - claude-3-sonnet-20240229: 200K tokens
# - claude-3-haiku-20240307: 200K tokens
```

### Multi-Agent Coordination

Normandy provides powerful patterns for coordinating multiple agents concurrently with different execution strategies.

#### Reactive Patterns

Execute multiple agents with different completion strategies:

```elixir
alias Normandy.Coordination.Reactive

# Race: Return first successful result (fastest response)
agents = [research_agent, cached_agent, search_agent]
{:ok, fastest_result} = Reactive.race(agents, "What is the capital of France?")

# All: Wait for all agents to complete (ensemble)
{:ok, all_results} = Reactive.all(agents, "Analyze this data")
#=> {:ok, %{
  "agent_0" => {:ok, result1},
  "agent_1" => {:ok, result2},
  "agent_2" => {:ok, result3}
}}

# Some: Wait for N successful results (quorum)
{:ok, quorum_results} = Reactive.some(agents, "Is this safe?", count: 2)
#=> {:ok, %{"agent_0" => result1, "agent_2" => result3}}
```

**Reactive Pattern Options:**

```elixir
# Race with timeout and callbacks
Reactive.race(agents, input,
  timeout: 5000,
  on_complete: fn agent_id, result ->
    Logger.info("Agent #{agent_id} completed: #{inspect(result)}")
  end
)

# All with concurrency control and fail-fast
Reactive.all(agents, input,
  max_concurrency: 5,
  fail_fast: true,
  timeout: 10_000,
  on_complete: fn agent_id, result ->
    update_progress(agent_id, result)
  end
)

# Some with callbacks
Reactive.some(agents, input,
  count: 3,
  timeout: 15_000,
  on_complete: fn agent_id, result ->
    Logger.debug("Got result from #{agent_id}")
  end
)
```

**Transform Agent Results:**

```elixir
# Map: Transform successful results
result = Reactive.map(agent, input, fn
  {:ok, %{confidence: c}} when c > 0.8 -> {:ok, :high_confidence}
  {:ok, %{confidence: c}} when c < 0.5 -> {:ok, :low_confidence}
  {:ok, _} -> {:ok, :medium_confidence}
  error -> error
end)

# when_result: Conditional execution based on results
Reactive.when_result(agent, input) do
  {:ok, %{needs_review: true}} ->
    AgentProcess.run(review_agent, "Please review")

  {:ok, %{confidence: c}} when c < 0.5 ->
    AgentProcess.run(fallback_agent, "Use fallback")

  {:ok, result} ->
    {:ok, result}

  error ->
    error
end
```

#### Agent Pooling

Efficiently manage pools of identical agents with automatic lifecycle management:

```elixir
alias Normandy.Coordination.AgentPool

# Start a pool of agents
{:ok, pool} = AgentPool.start_link(
  name: :research_pool,
  agent_config: %{
    client: client,
    model: "claude-3-5-sonnet-20241022",
    temperature: 0.7
  },
  size: 10,              # Fixed pool size
  max_overflow: 5,       # Allow 5 overflow agents
  strategy: :fifo        # :fifo or :lifo checkout
)

# Use transaction for automatic checkout/checkin
{:ok, result} = AgentPool.transaction(pool, fn agent_pid ->
  AgentProcess.run(agent_pid, "Analyze this data")
end)

# Manual checkout/checkin for more control
{:ok, agent_pid} = AgentPool.checkout(pool)
result = AgentProcess.run(agent_pid, input)
:ok = AgentPool.checkin(pool, agent_pid)

# Get pool statistics
stats = AgentPool.stats(pool)
#=> %{
  size: 10,
  available: 7,
  in_use: 3,
  overflow: 0,
  max_overflow: 5,
  waiting: 0
}
```

**Pool Configuration Options:**

```elixir
AgentPool.start_link(
  name: :my_pool,
  agent_config: agent_config,
  size: 10,              # Base pool size
  max_overflow: 5,       # Max overflow agents when pool exhausted
  strategy: :lifo        # :lifo (stack) or :fifo (queue)
)

# Non-blocking checkout
case AgentPool.checkout(pool, block: false) do
  {:ok, agent_pid} -> use_agent(agent_pid)
  {:error, :no_agents} -> handle_pool_exhausted()
end

# Checkout with timeout
{:ok, agent_pid} = AgentPool.checkout(pool, timeout: 10_000)
```

**Pool Features:**

- **Fault Tolerance** - Automatic agent replacement on failure
- **Overflow Handling** - Temporary agents when pool exhausted
- **Waiting Queue** - Block and queue checkout requests
- **Statistics** - Monitor pool health and usage
- **Supervision** - Built on AgentSupervisor for resilience

#### Agent Processes

Long-running agent processes with GenServer lifecycle:

```elixir
alias Normandy.Coordination.{AgentProcess, AgentSupervisor}

# Start a supervised agent process
{:ok, supervisor} = AgentSupervisor.start_link()
{:ok, agent_pid} = AgentSupervisor.start_agent(supervisor, agent: agent)

# Or start standalone
{:ok, agent_pid} = AgentProcess.start_link(agent: agent)

# Run agent
{:ok, response} = AgentProcess.run(agent_pid, "Hello!")

# Get agent state
agent = AgentProcess.get_agent(agent_pid)

# Update agent configuration
:ok = AgentProcess.update_agent(agent_pid, fn agent ->
  %{agent | temperature: 0.9}
end)

# Stop gracefully
:ok = AgentProcess.stop(agent_pid)
```

**Use Cases:**

- **Race Pattern** - Get fastest response for time-sensitive operations
- **All Pattern** - Ensemble methods, need all perspectives
- **Some Pattern** - Quorum-based decisions, majority agreement
- **Agent Pools** - Reuse agents efficiently, handle high concurrency
- **Agent Processes** - Long-lived agents with state management

### Conversation Summarization

When conversations grow too long, Normandy can automatically summarize old messages using an LLM to preserve context while reducing token usage.

```elixir
alias Normandy.Context.Summarizer

# Summarize specific messages
messages = AgentMemory.history(agent.memory)
{:ok, summary} = Summarizer.summarize_messages(client, agent, messages)
#=> "User discussed project requirements, assistant provided implementation suggestions"

# Compress conversation by replacing old messages with summary
{:ok, updated_agent} = Summarizer.compress_conversation(
  client,
  agent,
  keep_recent: 10  # Keep 10 most recent messages
)

# The updated agent now has:
# - A summary message replacing old messages
# - 10 most recent messages preserved
# - Significantly reduced token count
```

**Summarization Options:**

```elixir
{:ok, updated_agent} = Summarizer.compress_conversation(
  client,
  agent,
  keep_recent: 10,              # Messages to keep (default: 10)
  summary_role: "system",       # Role for summary message (default: "system")
  max_tokens: 500,              # Max tokens for summary (default: 500)
  prompt: "Custom prompt..."    # Custom summarization prompt
)
```

**Automatic Summarization with WindowManager:**

The `:summarize` strategy automatically summarizes old messages when approaching token limits:

```elixir
# Use summarization strategy
manager = WindowManager.new(
  max_tokens: 100_000,
  strategy: :summarize
)

# Automatically summarizes when needed
{:ok, updated_agent} = WindowManager.ensure_within_limit(agent, manager)

# The agent now has:
# - Old messages summarized into a single system message
# - Recent messages preserved for context
# - Token count reduced to stay within limits
```

**Estimate Token Savings:**

```elixir
# Estimate how many tokens you'll save
messages = AgentMemory.history(agent.memory)
{:ok, savings} = Summarizer.estimate_savings(messages, summary_tokens: 200)
#=> %{
  original: 1500,
  summary: 200,
  savings: 1300,
  savings_percent: 86.7
}

IO.puts("Summarization will save ~#{savings.savings_percent}% tokens")
```

**How It Works:**

1. **Split Conversation** - Splits history into old (to summarize) and recent (to keep)
2. **Generate Summary** - Uses LLM to create concise summary of old messages
3. **Replace Messages** - Replaces old messages with single summary message
4. **Preserve Context** - Keeps recent messages intact for immediate context

**Benefits:**

- Preserve conversation context while reducing tokens
- Stay within model context limits for long conversations
- Lower costs by reducing input tokens
- Automatic integration with WindowManager

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

### Batch Processing System

- **Normandy.Batch.Processor** - Concurrent batch processing with Task.async_stream

### Context Management System

- **Normandy.Context.WindowManager** - Token limit management and automatic truncation
- **Normandy.Context.TokenCounter** - Accurate token counting via Anthropic API
- **Normandy.Context.Summarizer** - LLM-based conversation summarization for context compression

### Multi-Agent Coordination System

- **Normandy.Coordination.Reactive** - Reactive patterns for concurrent agent execution (race, all, some)
- **Normandy.Coordination.AgentPool** - Pool manager with overflow handling and fault tolerance
- **Normandy.Coordination.AgentProcess** - GenServer-based agent processes
- **Normandy.Coordination.AgentSupervisor** - DynamicSupervisor for agent fault tolerance

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

## Acknowledgments

Schema system design inspired by [Ecto](https://github.com/elixir-ecto/ecto)'s elegant approach to data validation and changesets.

---

**Made with Elixir** 💜
