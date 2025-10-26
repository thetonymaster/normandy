# Claudio Integration Quick Start Guide

A quick reference for Normandy developers integrating with the Claudio library.

---

## Module Map

### Claudio Core Modules

```
Claudio                          Main module, documentation
├── Claudio.Client               HTTP client setup and auth
├── Claudio.Messages             Messages API (legacy + new)
│   ├── .Request                 Fluent request builder
│   ├── .Response                Structured response parser
│   └── .Stream                  SSE event streaming
├── Claudio.Tools                Tool/function calling
├── Claudio.Batches              Async batch processing
└── Claudio.APIError             Structured error handling
```

### Normandy Integration Points

```
Normandy                         Main library
├── Agents
│   ├── BaseAgent                ← Needs Claudio client
│   ├── Model                    ← Add Claudio model support
│   └── IOModel                  ← Add Claudio-specific IO
├── Components
│   ├── Message                  ← Store in Claudio format
│   ├── AgentMemory              ← Maintain Claudio message history
│   └── ToolCall                 ← Convert to Claudio tool format
├── Tools
│   ├── Executor                 ← Execute for Claudio responses
│   └── Registry                 ← Register tools
└── LLM                          ← NEW: Claudio adapter layer
    └── ClaudoAdapter            ← Request/response conversion
```

---

## Data Flow Diagram

```
User Input
    |
    v
+---────────────────────────────+
| Normandy Agent                |
| - Builds conversation         |
| - Manages memory              |
| - Orchestrates tool calls     |
+---────────────────────────────+
    |
    v
+---────────────────────────────+
| ClaudoAdapter (NEW)           |
| - Convert to Claudio format   |
| - Add tools if needed         |
| - Handle streaming            |
+---────────────────────────────+
    |
    v
+---────────────────────────────+
| Claudio.Messages              |
| - Build Request struct        |
| - Call API                    |
| - Parse Response              |
+---────────────────────────────+
    |
    v
+---────────────────────────────+
| Anthropic API (Claude)        |
| - Process request             |
| - Run tools if needed         |
| - Return response             |
+---────────────────────────────+
    |
    v
+---────────────────────────────+
| Response Handling             |
| - Extract text                |
| - Detect tool use             |
| - Parse streaming events      |
+---────────────────────────────+
    |
    v
+---────────────────────────────+
| Normandy Agent (Continued)    |
| - Store in memory             |
| - Execute tools (if needed)   |
| - Continue conversation       |
+---────────────────────────────+
    |
    v
Final Response / Agent Result
```

---

## Basic Integration Code

### 1. Client Creation

```elixir
defmodule Normandy.LLM.ClaudoAdapter do
  alias Claudio.Messages.{Request, Response}
  alias Claudio.Tools

  def new_client(api_key, opts \\ []) do
    version = Keyword.get(opts, :version, "2023-06-01")
    
    Claudio.Client.new(%{
      token: api_key,
      version: version
    })
  end

  # Map Normandy config to Claudio client
  def from_config(config) do
    new_client(config[:api_key], config[:claudio_opts] || [])
  end
end
```

### 2. Request Building

```elixir
def build_request(client, params) do
  model = params[:model] || "claude-3-5-sonnet-20241022"
  messages = params[:messages] || []
  tools = params[:tools] || []
  
  request = Request.new(model)
  
  # Add messages
  request = Enum.reduce(messages, request, fn msg, req ->
    Request.add_message(req, String.to_atom(msg["role"]), msg["content"])
  end)
  
  # Add tools if present
  request = Enum.reduce(tools, request, fn tool, req ->
    claudio_tool = %{
      "name" => tool["name"],
      "description" => tool["description"],
      "input_schema" => tool["input_schema"]
    }
    Request.add_tool(req, claudio_tool)
  end)
  
  # Add parameters
  request
  |> maybe_set_system(params[:system])
  |> maybe_set_max_tokens(params[:max_tokens])
  |> maybe_set_temperature(params[:temperature])
  |> maybe_enable_streaming(params[:stream])
end

defp maybe_set_system(request, nil), do: request
defp maybe_set_system(request, system) when is_binary(system) do
  Request.set_system(request, system)
end

defp maybe_set_max_tokens(request, nil), do: request
defp maybe_set_max_tokens(request, max_tokens) do
  Request.set_max_tokens(request, max_tokens)
end

defp maybe_set_temperature(request, nil), do: request
defp maybe_set_temperature(request, temp) do
  Request.set_temperature(request, temp)
end

defp maybe_enable_streaming(request, true) do
  Request.enable_streaming(request)
end
defp maybe_enable_streaming(request, _), do: request
```

### 3. Response Handling

```elixir
def handle_response({:ok, response}, _client, _params) do
  # Convert Claudio response to Normandy format
  %{
    text: Response.get_text(response),
    tool_uses: Response.get_tool_uses(response),
    stop_reason: response.stop_reason,
    usage: response.usage,
    original_response: response
  }
end

def handle_response({:error, %Claudio.APIError{type: :rate_limit_error} = error}, client, params) do
  # Implement retry logic
  Process.sleep(1000)
  call_api(client, params)
end

def handle_response({:error, %Claudio.APIError{} = error}, _client, _params) do
  {:error, error}
end

def handle_response({:error, reason}, _client, _params) do
  {:error, reason}
end
```

### 4. Tool Handling

```elixir
def extract_tool_calls(response) do
  response
  |> Response.get_tool_uses()
  |> Enum.map(fn tool_use ->
    %{
      id: tool_use.id,
      name: tool_use.name,
      arguments: tool_use.input
    }
  end)
end

def create_tool_result(tool_id, result, is_error \\ false) do
  # Convert to Claudio format
  claudio_result = Tools.create_tool_result(tool_id, result, is_error)
  
  # Return in Normandy-compatible format
  %{
    type: :tool_result,
    tool_use_id: tool_id,
    content: result
  }
end
```

### 5. Streaming

```elixir
def stream_response(client, request_params) do
  client
  |> Claudio.Messages.create(build_request(client, request_params))
  |> case do
    {:ok, %Tesla.Env{body: body}} ->
      # Parse streaming response
      body
      |> Claudio.Messages.Stream.parse_events()
      |> Stream.map(&parse_stream_event/1)
    
    {:error, reason} ->
      Stream.emit({:error, reason})
  end
end

defp parse_stream_event({:ok, %{event: "content_block_delta", data: data}}) do
  case data do
    %{"delta" => %{"type" => "text_delta", "text" => text}} ->
      {:stream_chunk, text}
    
    %{"delta" => %{"type" => "input_json_delta", "partial_json" => json}} ->
      {:stream_json, json}
    
    _ -> 
      nil
  end
end

defp parse_stream_event({:ok, %{event: "message_stop"}}) do
  {:stream_end, nil}
end

defp parse_stream_event({:ok, _event}) do
  nil  # Ignore other events
end

defp parse_stream_event({:error, reason}) do
  {:error, reason}
end
```

---

## Common Patterns

### Pattern 1: Simple Message Exchange

```elixir
client = ClaudoAdapter.new_client(api_key)

request = ClaudoAdapter.build_request(client, %{
  model: "claude-3-5-sonnet-20241022",
  messages: [%{"role" => "user", "content" => "Hello!"}],
  max_tokens: 1024
})

{:ok, response} = Claudio.Messages.create(client, request)
text = Claudio.Messages.Response.get_text(response)
```

### Pattern 2: Tool Use

```elixir
# 1. Define tools
tools = [
  %{
    "name" => "get_weather",
    "description" => "Get weather",
    "input_schema" => %{"type" => "object", "properties" => %{}}
  }
]

# 2. Create request with tools
request = ClaudoAdapter.build_request(client, %{
  messages: messages,
  tools: tools
})

# 3. Get response
{:ok, response} = Claudio.Messages.create(client, request)

# 4. Check for tool use
if response.stop_reason == :tool_use do
  tool_uses = Claudio.Messages.Response.get_tool_uses(response)
  
  # 5. Execute tools
  results = Enum.map(tool_uses, fn tool ->
    output = execute_tool(tool.name, tool.input)
    Claudio.Tools.create_tool_result(tool.id, output)
  end)
  
  # 6. Continue conversation
  new_request = request
    |> Claudio.Messages.Request.add_message(:assistant, response.content)
    |> Claudio.Messages.Request.add_message(:user, results)
  
  {:ok, final_response} = Claudio.Messages.create(client, new_request)
end
```

### Pattern 3: Streaming with Tools

```elixir
request = ClaudoAdapter.build_request(client, %{
  messages: messages,
  tools: tools,
  stream: true
})

{:ok, stream} = Claudio.Messages.create(client, request)

stream
|> Claudio.Messages.Stream.parse_events()
|> Stream.each(fn {:ok, event} ->
  case event do
    %{event: "content_block_delta", data: %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
      emit_chunk(text)
    
    %{event: "message_stop"} ->
      # End of stream, check for tool use in accumulated content
      emit_final()
  end
end)
|> Stream.run()
```

---

## Error Handling Quick Reference

```elixir
case result do
  {:ok, response} ->
    # Success
    process_response(response)

  {:error, %Claudio.APIError{type: :authentication_error}} ->
    # Bad API key
    {:error, :invalid_api_key}

  {:error, %Claudio.APIError{type: :rate_limit_error}} ->
    # Too many requests - implement backoff
    {:error, :rate_limited}

  {:error, %Claudio.APIError{type: :invalid_request_error, message: msg}} ->
    # Bad request format
    {:error, {:bad_request, msg}}

  {:error, %Claudio.APIError{type: :overloaded_error}} ->
    # API overloaded - retry later
    {:error, :service_overloaded}

  {:error, reason} ->
    # Other error
    {:error, reason}
end
```

---

## Configuration Example

```elixir
# config/config.exs
config :normandy,
  llm_adapter: Normandy.LLM.ClaudoAdapter,
  llm_config: %{
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    default_model: "claude-3-5-sonnet-20241022",
    claudio_opts: [
      version: "2023-06-01"
    ]
  }
```

---

## Key Takeaways

1. **Claudio is modular** - Use only what you need
2. **Request builder pattern** - Fluent API for building requests
3. **Streaming is first-class** - Full SSE support built-in
4. **Tools are well-designed** - Schema-based tool definitions
5. **Error handling is structured** - Type-safe error matching
6. **Backward compatible** - Both new and legacy APIs available
7. **Type safe** - Extensive @spec and @type usage

---

## Resources

- Main Analysis: See `CLAUDIO_INTEGRATION_ANALYSIS.md`
- Integration Checklist: See `CLAUDIO_INTEGRATION_CHECKLIST.md`
- Claudio Repo: https://github.com/anthropics/claudio
- API Docs: https://docs.anthropic.com/

---

## Next Steps

1. Add `:claudio` to `mix.exs` dependencies
2. Create `lib/normandy/lm/claudio_adapter.ex`
3. Implement basic client setup
4. Build request/response converters
5. Test with simple message flow
6. Add tool support
7. Add streaming support
8. Implement error handling

