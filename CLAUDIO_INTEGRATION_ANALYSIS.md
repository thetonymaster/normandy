# Claudio Library Architecture Analysis
## Comprehensive Integration Guide for Normandy Library

**Repository:** https://github.com/anthropics/claudio (Elixir)  
**Current Commit:** 591ec36  
**Analysis Date:** 2025-10-26

---

## Executive Summary

Claudio is a feature-complete Elixir client library for the Anthropic API (Claude models). It provides:

- **Messages API** with full streaming support
- **Batches API** for large-scale asynchronous processing (up to 100,000 requests)
- **Tool/Function Calling** with schema support
- **Prompt Caching** (up to 90% cost reduction)
- **Vision/Multimodal Support** (images, documents)
- **MCP (Model Context Protocol) Server** integration
- **Extended Thinking** configuration
- **Structured Response Handling** with type safety
- **Comprehensive Error Handling** with error-specific types

The library uses Tesla HTTP client with Poison/Jason for JSON, and emphasizes backward compatibility while providing modern APIs.

---

## 1. Architecture Overview

### 1.1 Module Organization

```
lib/claudio/
├── claudio.ex                 # Main module with documentation and examples
├── client.ex                  # HTTP client configuration and setup
├── api_error.ex               # Structured error handling
├── messages.ex                # Main Messages API (legacy + new)
├── messages/
│   ├── request.ex             # Fluent request builder
│   ├── response.ex            # Response parser with type safety
│   └── stream.ex              # SSE streaming utilities
├── tools.ex                   # Tool/function calling utilities
└── batches.ex                 # Batches API for async processing
```

### 1.2 Core Design Patterns

#### Builder Pattern (Request)
```elixir
Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "Hello")
|> Request.set_temperature(0.7)
|> Request.to_map()  # Convert to API payload
```

#### Streaming with Events
```elixir
stream
|> Claudio.Messages.Stream.parse_events()
|> Stream.accumulate_text()
|> Enum.each(&IO.write/1)
```

#### Type Safety
- Extensive use of `@spec` and `@type` for Dialyzer
- Content blocks typed by `:type` field
- Stop reasons converted to atoms for pattern matching

---

## 2. Protocol Definitions & Type System

### 2.1 Request Protocol

**Module:** `Claudio.Messages.Request`

```elixir
@type t :: %__MODULE__{
  model: String.t(),
  messages: list(map()),
  max_tokens: integer() | nil,
  system: String.t() | list() | nil,
  temperature: float() | nil,
  top_p: float() | nil,
  top_k: integer() | nil,
  stop_sequences: list(String.t()) | nil,
  stream: boolean() | nil,
  tools: list(map()) | nil,
  tool_choice: map() | nil,
  metadata: map() | nil,
  thinking: map() | nil,
  mcp_servers: list(map()) | nil,
  context_management: map() | nil,
  container: String.t() | map() | nil,
  service_tier: String.t() | nil
}
```

**Key Methods:**
- `new(model)` - Create new request
- `add_message(request, role, content)` - Add user/assistant message
- `set_system(request, system)` - Set system prompt
- `set_system_with_cache(request, text, opts)` - With prompt caching
- `set_max_tokens(request, max)` - Set token limit
- `set_temperature(request, temp)` - Set temperature (0.0-1.0)
- `set_top_p(request, p)` - Nucleus sampling
- `set_top_k(request, k)` - Top-K sampling
- `set_stop_sequences(request, sequences)` - Custom stop sequences
- `enable_streaming(request)` - Enable streaming mode
- `add_message_with_image(request, role, text, base64_data, media_type)` - Vision
- `add_message_with_image_url(request, role, text, url)` - URL-based images
- `add_message_with_document(request, role, text, file_id)` - PDF/documents
- `add_tool(request, tool)` - Add tool definition
- `add_tool_with_cache(request, tool, opts)` - With prompt caching
- `set_tool_choice(request, choice)` - Set tool strategy (:auto, :any, {:tool, name}, :none)
- `set_metadata(request, metadata)` - Request metadata
- `enable_thinking(request, config)` - Extended thinking
- `add_mcp_server(request, server)` - MCP server definition
- `set_context_management(request, config)` - Context management
- `set_container(request, container)` - Container for tool state
- `set_service_tier(request, tier)` - Capacity selection ("auto" or "standard_only")
- `to_map(request)` - Convert to API payload

### 2.2 Response Protocol

**Module:** `Claudio.Messages.Response`

```elixir
@type stop_reason ::
  :end_turn
  | :max_tokens
  | :stop_sequence
  | :tool_use
  | :pause_turn
  | :refusal
  | :model_context_window_exceeded

@type content_block ::
  text_block()
  | thinking_block()
  | tool_use_block()
  | tool_result_block()

@type text_block :: %{
  type: :text,
  text: String.t()
}

@type thinking_block :: %{
  type: :thinking,
  thinking: String.t()
}

@type tool_use_block :: %{
  type: :tool_use,
  id: String.t(),
  name: String.t(),
  input: map()
}

@type tool_result_block :: %{
  type: :tool_result,
  tool_use_id: String.t(),
  content: String.t() | list()
}

@type usage :: %{
  input_tokens: integer(),
  output_tokens: integer(),
  cache_creation_input_tokens: integer() | nil,
  cache_read_input_tokens: integer() | nil
}

@type t :: %__MODULE__{
  id: String.t(),
  type: String.t(),
  role: String.t(),
  model: String.t(),
  content: list(content_block()),
  stop_reason: stop_reason() | nil,
  stop_sequence: String.t() | nil,
  usage: usage()
}
```

**Key Methods:**
- `from_map(data)` - Parse API response
- `get_text(response)` - Extract all text content
- `get_tool_uses(response)` - Extract tool use requests

### 2.3 Stream Protocol

**Module:** `Claudio.Messages.Stream`

```elixir
@type event :: %{
  event: String.t(),
  data: map() | nil
}

@type parsed_event :: {:ok, event()} | {:error, term()}
```

**Event Types:**
- `message_start` - Initial message with empty content
- `content_block_start` - Beginning of content block
- `content_block_delta` - Incremental content updates
- `content_block_stop` - End of content block
- `message_delta` - Top-level message changes (usage updates)
- `message_stop` - Stream completion
- `ping` - Keep-alive events
- `error` - Error events

**Delta Types:**
- `text_delta` - Text chunks
- `input_json_delta` - Partial JSON for tool parameters
- `thinking_delta` - Extended thinking content

**Key Methods:**
- `parse_events(stream)` - Convert raw stream to structured events
- `accumulate_text(event_stream)` - Extract and accumulate text deltas
- `filter_events(event_stream, event_types)` - Filter to specific event types
- `build_final_message(event_stream)` - Accumulate all events into final message

---

## 3. LLM Interaction Patterns

### 3.1 Basic Message Creation

```elixir
client = Claudio.Client.new(%{
  token: "your-api-key",
  version: "2023-06-01"
})

request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "Hello!")
|> Request.set_max_tokens(1024)

{:ok, response} = Claudio.Messages.create(client, request)
text = Response.get_text(response)
```

### 3.2 Streaming Mode

```elixir
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "Tell me a story")
|> Request.set_max_tokens(1024)
|> Request.enable_streaming()

{:ok, stream} = Claudio.Messages.create(client, request)

stream
|> Claudio.Messages.Stream.parse_events()
|> Claudio.Messages.Stream.accumulate_text()
|> Enum.each(&IO.write/1)
```

### 3.3 Tool Use Flow

```elixir
# 1. Define tools
weather_tool = Tools.define_tool(
  "get_weather",
  "Get weather for a location",
  %{
    "type" => "object",
    "properties" => %{
      "location" => %{"type" => "string"}
    },
    "required" => ["location"]
  }
)

# 2. Create request with tool
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "What's the weather in Paris?")
|> Request.add_tool(weather_tool)
|> Request.set_max_tokens(1024)

# 3. Get response
{:ok, response} = Claudio.Messages.create(client, request)

# 4. Extract tool uses
if Tools.has_tool_uses?(response) do
  tool_uses = Tools.extract_tool_uses(response)
  
  # Execute tools and create results
  results = Enum.map(tool_uses, fn tool_use ->
    result = execute_my_tool(tool_use.name, tool_use.input)
    Tools.create_tool_result(tool_use.id, result)
  end)
  
  # 5. Continue conversation with tool results
  request2 = Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message(:user, "What's the weather in Paris?")
  |> Request.add_message(:assistant, response.content)
  |> Request.add_message(:user, results)
  
  {:ok, final_response} = Claudio.Messages.create(client, request2)
end
```

### 3.4 Token Counting

```elixir
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "Hello!")

{:ok, count} = Claudio.Messages.count_tokens(client, request)
IO.puts("Input tokens: #{count.input_tokens}")
```

---

## 4. Client Configuration & Initialization

### 4.1 Basic Client Creation

```elixir
client = Claudio.Client.new(%{
  token: System.get_env("ANTHROPIC_API_KEY"),
  version: "2023-06-01"
})
```

### 4.2 With Beta Features

```elixir
client = Claudio.Client.new(%{
  token: "your-api-key",
  version: "2023-06-01",
  beta: ["prompt-caching-2024-07-31"]
})
```

### 4.3 With Custom Endpoint

```elixir
client = Claudio.Client.new(
  %{token: "key", version: "2023-06-01"},
  "https://custom.api.endpoint/v1/"
)
```

### 4.4 Configuration File

```elixir
# config/config.exs
config :claudio,
  default_api_version: "2023-06-01",
  default_beta_features: []

config :claudio, Claudio.Client,
  adapter: Tesla.Adapter.Mint,
  timeout: 60_000,
  recv_timeout: 120_000,
  retry: true  # or list of retry options
```

### 4.5 Headers Set by Client

- `user-agent: claudio`
- `anthropic-version: {version}`
- `x-api-key: {token}`
- `anthropic-beta: {beta_features}` (if beta features enabled)

---

## 5. Response Handling & Data Structures

### 5.1 Response Parsing

The library automatically parses API responses into structured `Response` structs:

```elixir
{:ok, response} = Claudio.Messages.create(client, request)

# Access response fields
IO.puts(response.id)           # Message ID
IO.puts(response.model)        # Model used
IO.puts(response.role)         # "assistant"
IO.puts(response.stop_reason)  # Atom: :end_turn, :tool_use, etc.

# Get usage metrics
IO.puts(response.usage.input_tokens)
IO.puts(response.usage.output_tokens)
IO.puts(response.usage.cache_creation_input_tokens)
IO.puts(response.usage.cache_read_input_tokens)

# Extract content
text = Response.get_text(response)
tool_uses = Response.get_tool_uses(response)
```

### 5.2 Content Block Types

Responses can contain different types of content blocks:

```elixir
# Text block
%{type: :text, text: "Hello"}

# Tool use block
%{type: :tool_use, id: "toolu_123", name: "get_weather", input: %{"location" => "Paris"}}

# Thinking block (extended thinking mode)
%{type: :thinking, thinking: "Let me think about this..."}

# Tool result block
%{type: :tool_result, tool_use_id: "toolu_123", content: "Result here"}
```

### 5.3 Streaming Event Handling

When streaming is enabled, the library provides utilities to handle events:

```elixir
{:ok, stream} = Claudio.Messages.create(client, streaming_request)

# Parse all events and filter
stream
|> Claudio.Messages.Stream.parse_events()
|> Stream.filter(&match?({:ok, %{event: "content_block_delta"}}, &1))
|> Enum.each(fn {:ok, event} ->
  IO.puts(event.data["delta"]["text"])
end)

# Or accumulate into final message
{:ok, final_message} =
  stream
  |> Claudio.Messages.Stream.parse_events()
  |> Claudio.Messages.Stream.build_final_message()
```

---

## 6. Error Handling

### 6.1 Error Type System

**Module:** `Claudio.APIError`

```elixir
@type error_type ::
  :invalid_request_error
  | :authentication_error
  | :permission_error
  | :not_found_error
  | :rate_limit_error
  | :api_error
  | :overloaded_error

@type t :: %__MODULE__{
  type: error_type() | String.t(),
  message: String.t(),
  status_code: integer(),
  raw_body: map() | nil
}
```

### 6.2 Error Handling Pattern

```elixir
case Claudio.Messages.create(client, request) do
  {:ok, response} ->
    IO.puts(Response.get_text(response))
  
  {:error, %Claudio.APIError{type: :rate_limit_error} = error} ->
    IO.puts("Rate limited: #{error.message}")
    # Implement retry logic
  
  {:error, %Claudio.APIError{type: :authentication_error} = error} ->
    IO.puts("Auth failed: #{error.message}")
  
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end
```

### 6.3 Error Information

- Status code available for HTTP-level handling
- Typed error reasons for pattern matching
- Raw response body preserved for debugging
- Human-readable error messages

---

## 7. Batch Processing API

**Module:** `Claudio.Batches`

### 7.1 Create Batch

```elixir
requests = [
  %{
    "custom_id" => "req-1",
    "params" => %{
      "model" => "claude-3-5-sonnet-20241022",
      "max_tokens" => 1024,
      "messages" => [%{"role" => "user", "content" => "Hello"}]
    }
  },
  %{
    "custom_id" => "req-2",
    "params" => %{
      "model" => "claude-3-5-sonnet-20241022",
      "max_tokens" => 1024,
      "messages" => [%{"role" => "user", "content" => "Hi"}]
    }
  }
]

{:ok, batch} = Claudio.Batches.create(client, requests)
```

### 7.2 Check Status

```elixir
{:ok, batch} = Claudio.Batches.get(client, batch_id)
IO.puts(batch["processing_status"])  # "in_progress", "canceling", or "ended"
IO.inspect(batch["request_counts"])  # {:processing, :succeeded, :errored}
```

### 7.3 Wait for Completion

```elixir
{:ok, final_batch} = Claudio.Batches.wait_for_completion(
  client,
  batch_id,
  poll_interval: 30,      # seconds
  timeout: 86_400,        # 24 hours
  callback: fn batch ->
    IO.puts("Status: #{batch["processing_status"]}")
  end
)
```

### 7.4 Get Results

```elixir
{:ok, results} = Claudio.Batches.get_results(client, batch_id)

Enum.each(results, fn result ->
  case result do
    %{"custom_id" => id, "result" => result} ->
      IO.puts("Success for #{id}")
      IO.inspect(result)
    
    %{"custom_id" => id, "error" => error} ->
      IO.puts("Error for #{id}")
      IO.inspect(error)
  end
end)
```

### 7.5 List & Manage Batches

```elixir
# List batches
{:ok, response} = Claudio.Batches.list(client, limit: 50)

# Cancel batch
{:ok, _} = Claudio.Batches.cancel(client, batch_id)

# Delete batch
{:ok, _} = Claudio.Batches.delete(client, batch_id)
```

---

## 8. Advanced Features

### 8.1 Prompt Caching

Reduces costs by up to 90% and latency by up to 85%.

```elixir
# System prompt with caching
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.set_system_with_cache("Long system prompt...", ttl: "1h")
|> Request.add_message(:user, "Question")

# Tools with caching
weather_tool = Tools.define_tool("get_weather", "Get weather", schema)
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_tool_with_cache(weather_tool)

# Check cache metrics in response
{:ok, response} = Claudio.Messages.create(client, request)
IO.puts(response.usage.cache_read_input_tokens)         # Tokens from cache
IO.puts(response.usage.cache_creation_input_tokens)     # Tokens written to cache
```

**TTL Options:**
- `"5m"` - 5 minutes (default, included)
- `"1h"` - 1 hour (extended, additional cost)

### 8.2 Vision/Image Support

```elixir
# Base64-encoded image
image_data = File.read!("image.jpg") |> Base.encode64()
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message_with_image(:user, "What's in this?", image_data, "image/jpeg")

# URL-based image
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message_with_image_url(:user, "Describe", "https://example.com/image.jpg")

# Files API
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, [
  %{"type" => "image", "source" => %{"type" => "file", "file_id" => "file_123"}},
  %{"type" => "text", "text" => "Analyze this"}
])
```

**Supported Formats:** JPEG, PNG, GIF, WebP  
**Limits:** Max 100 images, 5MB each, up to 8000x8000px

### 8.3 Document Support

```elixir
# PDF via Files API
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message_with_document(:user, "Summarize", "file_abc123")

# With caching for large documents
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, [
  %{
    "type" => "document",
    "source" => %{"type" => "file", "file_id" => "file_large"},
    "cache_control" => %{"type" => "ephemeral"}
  },
  %{"type" => "text", "text" => "What are key points?"}
])
```

### 8.4 MCP (Model Context Protocol) Servers

```elixir
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_mcp_server(%{
  "name" => "my_server",
  "url" => "http://localhost:8080"
})
|> Request.add_message(:user, "Use the MCP server")
```

### 8.5 Extended Thinking

```elixir
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 1000})
|> Request.add_message(:user, "Complex problem")
```

---

## 9. Integration Points for Normandy

### 9.1 Key Integration Areas

1. **Model Interface**
   - Implement `Claudio.Client` initialization in Normandy's model layer
   - Map Normandy's model abstraction to Claudio's request/response

2. **Tool Integration**
   - Adapter between Normandy's `Tools` system and Claudio's tool format
   - Convert Claudio's tool use responses to Normandy's format
   - Implement tool result creation using `Claudio.Tools.create_tool_result/3`

3. **Streaming Support**
   - Use `Claudio.Messages.Stream` for real-time response handling
   - Adapt stream events to Normandy's streaming interface
   - Map `content_block_delta` events to Normandy chunks

4. **Agent Memory**
   - Store message history compatible with Claudio's message format
   - Support conversation continuity with tool results

5. **Error Handling**
   - Map `Claudio.APIError` types to Normandy's error system
   - Preserve error context and metadata

### 9.2 Message Conversion

Claudio messages use this format:
```elixir
%{
  "role" => "user" | "assistant",
  "content" => String.t() | list()  # Can include tool results
}
```

Tool result content in messages:
```elixir
[
  %{
    "type" => "tool_result",
    "tool_use_id" => "toolu_123",
    "content" => "Result text",
    "is_error" => false
  }
]
```

### 9.3 Recommended Integration Pattern

1. Create a `Claudio.LLMAdapter` module in Normandy that:
   - Wraps `Claudio.Client` initialization
   - Converts Normandy requests to Claudio `Request` structs
   - Converts Claudio `Response` structs back to Normandy format
   - Handles streaming event conversion
   - Maps error types

2. Extend agent flow to:
   - Build Claudio requests with tool definitions
   - Extract tool uses from responses
   - Execute tools via Normandy's tool system
   - Create tool results using Claudio's format
   - Maintain message history for conversation continuity

3. Support streaming at agent level by:
   - Using `Claudio.Messages.Stream.parse_events/1`
   - Emitting Normandy `StreamChunk` events
   - Accumulating state for tool use detection

---

## 10. Key Implementation Considerations

### 10.1 Backward Compatibility

- Legacy `create_message/2` API maintained alongside new `create/2`
- Both string and atom keys supported in response parsing
- Error responses return structured `APIError` but use standard `:error` tuples

### 10.2 JSON Handling

- Poison used for production (no external dependencies)
- Jason used only in tests
- All API responses parsed with atom keys for ease of access
- Configuration preserves backward compatibility with string keys

### 10.3 Streaming Implementation

- Streaming detected by pattern matching on `stream: true`
- SSE parsing handles incomplete chunks via buffer accumulation
- Events extracted by parsing `event:` and `data:` lines
- Unknown event types handled gracefully (forward compatible)

### 10.4 Type Safety

- Extensive use of `@spec` and `@type` for documentation
- Stop reasons converted to atoms for pattern matching
- Content blocks typed by their `:type` field
- Dialyzer-friendly code structure

### 10.5 API Versioning

- Default version: "2023-06-01"
- Configurable per client
- Beta features specified as list in client config
- Version header passed with every request

---

## 11. Testing Strategy

The library uses:
- **Mox** for mocking Tesla HTTP calls
- **ExUnit** with `async: true` for parallel tests
- **Tesla.Test** helpers for verifying HTTP interactions
- Comprehensive test coverage: 55+ tests

**Test Coverage:**
- `test/messages_test.exs` - Legacy Messages API
- `test/request_test.exs` - Request builder (55+ assertions)
- `test/response_test.exs` - Response parsing
- `test/tools_test.exs` - Tool utilities
- `test/api_error_test.exs` - Error handling
- `test/integration/` - Integration tests with real-like scenarios

---

## 12. Dependency Information

### 12.1 Required Dependencies

```elixir
# HTTP client
{:tesla, "~> 1.11"}

# JSON encoding/decoding
{:poison, "~> 6.0"}

# Tesla adapter (recommended)
{:mint, "~> 1.0"}
```

### 12.2 Optional Dependencies

```elixir
# Testing only
{:mox, "~> 1.0", only: :test}
{:jason, "~> 1.4", only: :test}
```

### 12.3 Logger Configuration

Requests/responses are automatically logged via `Tesla.Middleware.Logger` at `:debug` level.

---

## 13. API Endpoints Covered

### Messages API
- `POST /v1/messages` - Create message (non-streaming)
- `POST /v1/messages` - Create message (streaming)
- `POST /v1/messages/count_tokens` - Count tokens

### Batches API
- `POST /v1/messages/batches` - Create batch
- `GET /v1/messages/batches/{batch_id}` - Get batch status
- `GET /v1/messages/batches/{batch_id}/results` - Get results
- `GET /v1/messages/batches` - List batches
- `POST /v1/messages/batches/{batch_id}/cancel` - Cancel batch
- `DELETE /v1/messages/batches/{batch_id}` - Delete batch

---

## 14. Complete Feature Checklist

✅ Messages API (create, streaming, count_tokens)
✅ Message Batches API (all 6 endpoints)
✅ Tool/Function Calling
✅ Prompt Caching
✅ Vision/Images (base64, URL, Files API)
✅ PDF/Document Support
✅ MCP Servers
✅ Extended Thinking
✅ All sampling parameters (temperature, top_p, top_k)
✅ Stop sequences
✅ Metadata
✅ Structured error handling
✅ Streaming with full event support
✅ Request builder pattern
✅ Response struct with type safety

---

## 15. Code Quality & Documentation

### 15.1 Code Organization

- Clear module separation by responsibility
- Extensive use of private helper functions
- Pattern matching for type safety
- Guard clauses for input validation

### 15.2 Documentation

- Comprehensive `@moduledoc` on all public modules
- `@doc` with examples on all public functions
- `@spec` type specifications throughout
- Well-commented private functions
- CLAUDE.md guide for development

### 15.3 Configuration

- Config-driven defaults
- Per-module configuration support
- Environment-specific config loading
- Middleware-based extension points

---

## Conclusion

Claudio is a mature, well-architected library providing complete coverage of the Anthropic API. For Normandy integration:

1. **Wrap Claudio's Request/Response** in adapter module
2. **Map tool definitions** between systems
3. **Implement streaming** using provided utilities
4. **Handle errors** using structured error types
5. **Maintain message history** in compatible format
6. **Support all advanced features** (caching, vision, etc.)

The library's builder pattern, type safety, and comprehensive error handling make it an excellent foundation for building higher-level abstractions.

