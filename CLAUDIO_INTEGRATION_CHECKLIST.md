# Claudio Integration Checklist for Normandy

This checklist outlines all the integration points that need to be implemented for full Claudio compatibility with Normandy.

---

## Phase 1: Core Integration (Must Have)

### 1.1 Client Setup
- [ ] Create `Normandy.LLM.ClaudoAdapter` module
- [ ] Implement client initialization from Normandy config
- [ ] Support API key configuration from environment/config
- [ ] Set default model from Normandy config

### 1.2 Basic Message Flow
- [ ] Map Normandy messages to Claudio `Request` format
- [ ] Convert Claudio `Response` back to Normandy format
- [ ] Handle text extraction from responses
- [ ] Support model/max_tokens/temperature parameters

### 1.3 Error Handling
- [ ] Map Claudio.APIError types to Normandy errors
- [ ] Preserve error context and messages
- [ ] Implement retry logic for rate limits
- [ ] Log API errors with full context

### 1.4 Tool Integration - Basic
- [ ] Convert Normandy tool definitions to Claudio format
- [ ] Map tool JSON schemas between systems
- [ ] Extract tool uses from responses
- [ ] Create tool result objects in Claudio format
- [ ] Add tool results to conversation history

### 1.5 Streaming Support
- [ ] Enable streaming mode in Claudio requests
- [ ] Parse Claudio SSE events
- [ ] Emit Normandy StreamChunk events
- [ ] Handle content_block_delta events
- [ ] Accumulate text deltas

### 1.6 Agent Memory
- [ ] Store messages in Claudio-compatible format
- [ ] Support tool results in message history
- [ ] Maintain conversation continuity
- [ ] Handle role consistency (user/assistant)

---

## Phase 2: Advanced Features (Should Have)

### 2.1 Tool Execution Loop
- [ ] Implement full tool use cycle
- [ ] Detect tool use in responses (stop_reason = :tool_use)
- [ ] Call Normandy's tool executor
- [ ] Create tool results with proper error handling
- [ ] Continue conversation with results

### 2.2 Streaming Enhancements
- [ ] Handle thinking blocks in streaming
- [ ] Support tool use detection in streams
- [ ] Accumulate incomplete tool uses from events
- [ ] Emit complete events to Normandy

### 2.3 Response Features
- [ ] Track cache metrics from responses
- [ ] Handle stop reasons properly
- [ ] Support different content block types
- [ ] Extract thinking content if present

### 2.4 Token Management
- [ ] Implement token counting
- [ ] Track tokens per turn/conversation
- [ ] Warn on approaching token limits
- [ ] Support max_tokens parameter

### 2.5 Prompt Engineering
- [ ] Support system prompts
- [ ] Support custom stop sequences
- [ ] Support temperature control
- [ ] Support top_p and top_k sampling

---

## Phase 3: Advanced Capabilities (Nice to Have)

### 3.1 Vision Support
- [ ] Support image messages
- [ ] Handle base64-encoded images
- [ ] Support URL-based images
- [ ] Support Files API references
- [ ] Include image in tool parameter handling

### 3.2 Document Support
- [ ] Support PDF documents via Files API
- [ ] Handle document references in messages
- [ ] Support document caching

### 3.3 Prompt Caching
- [ ] Implement system prompt caching
- [ ] Implement tool definition caching
- [ ] Track cache hit/miss rates
- [ ] Configure TTL options

### 3.4 Extended Thinking
- [ ] Support thinking mode in requests
- [ ] Extract thinking content from responses
- [ ] Configure budget tokens
- [ ] Display thinking in streaming

### 3.5 MCP Integration
- [ ] Support MCP server configuration
- [ ] Pass MCP servers to Claudio
- [ ] Handle MCP-provided tools

### 3.6 Batch Processing
- [ ] Create batch processing wrapper
- [ ] Support large-scale async operations
- [ ] Implement progress tracking
- [ ] Handle batch results parsing

---

## Phase 4: Testing & Documentation

### 4.1 Unit Tests
- [ ] Test basic message flow
- [ ] Test error handling
- [ ] Test tool integration
- [ ] Test streaming parsing
- [ ] Test response conversion

### 4.2 Integration Tests
- [ ] Test full agent flow with tools
- [ ] Test streaming with tool use
- [ ] Test error recovery
- [ ] Test batch operations

### 4.3 Documentation
- [ ] Document Claudio adapter API
- [ ] Document configuration options
- [ ] Add examples to README
- [ ] Document advanced features
- [ ] Add troubleshooting guide

---

## Implementation Priority Matrix

```
High Impact, Low Effort (Do First)
- [x] Client setup
- [x] Basic message flow
- [x] Error handling
- [x] Tool integration

High Impact, Medium Effort (Do Next)
- [ ] Tool execution loop
- [ ] Streaming enhancements
- [ ] Token management
- [ ] Response features

Medium Impact, Low Effort (Add-ons)
- [ ] Prompt engineering features
- [ ] Vision support
- [ ] Document support

Medium Impact, Medium Effort (Long-term)
- [ ] Prompt caching
- [ ] Extended thinking
- [ ] MCP integration
- [ ] Batch processing
```

---

## Key Files to Create/Modify

### Create:
```
lib/normandy/lm/claudio_adapter.ex       # Main adapter
lib/normandy/lm/claudio_adapter/...      # Supporting modules
test/normandy/lm/claudio_adapter_test.exs # Tests
CLAUDIO_INTEGRATION_ANALYSIS.md           # Architecture (done)
```

### Modify:
```
lib/normandy/agents/base_agent.ex        # Add Claudio client
lib/normandy/agents/model.ex             # Support Claudio models
lib/normandy/agents/io_model.ex          # Claudio-specific IO
lib/normandy/components/agent_memory.ex  # Store Claudio messages
lib/normandy/tools/executor.ex           # Execute for Claudio
mix.exs                                   # Add :claudio dependency
```

---

## Claudio API Quick Reference

### Client Creation
```elixir
client = Claudio.Client.new(%{
  token: api_key,
  version: "2023-06-01"
})
```

### Making Requests
```elixir
request = Claudio.Messages.Request.new(model)
  |> Request.add_message(:user, content)
  |> Request.to_map()

{:ok, response} = Claudio.Messages.create(client, request)
```

### Parsing Responses
```elixir
text = Claudio.Messages.Response.get_text(response)
tool_uses = Claudio.Messages.Response.get_tool_uses(response)
```

### Tools
```elixir
tool = Claudio.Tools.define_tool(name, description, schema)
results = Claudio.Tools.extract_tool_uses(response)
result = Claudio.Tools.create_tool_result(tool_id, output)
```

### Streaming
```elixir
{:ok, stream} = Claudio.Messages.create(client, stream_request)
stream
  |> Claudio.Messages.Stream.parse_events()
  |> Claudio.Messages.Stream.accumulate_text()
```

### Error Handling
```elixir
case Claudio.Messages.create(client, request) do
  {:ok, response} -> ...
  {:error, %Claudio.APIError{type: type}} -> ...
end
```

---

## Testing Strategy

### Unit Test Template
```elixir
test "converts Normandy request to Claudio format" do
  normandy_request = ...
  claudio_request = ClaudoAdapter.to_claudio_request(normandy_request)
  assert claudio_request.model == "claude-3-5-sonnet-20241022"
end
```

### Mock Client Setup
```elixir
# Use Mox to mock Claudio responses
Mox.stub(ClaudoHTTPMock, :post, fn _url, _payload ->
  {:ok, claudio_response}
end)
```

### Integration Test
```elixir
# Use real Claudio in test environment (requires API key)
test "full agent flow with tools" do
  # 1. Create agent with Claudio adapter
  # 2. Execute with user message
  # 3. Verify tool was called
  # 4. Verify final response
end
```

---

## Known Considerations

1. **Message Format**: Claudio uses string keys by default, ensure consistent conversion
2. **Content Blocks**: Different block types (:text, :tool_use, :thinking) require special handling
3. **Streaming**: Must use `Stream` module for SSE parsing
4. **Stop Reasons**: Map to atoms for pattern matching
5. **Error Types**: Different error types have different retry strategies
6. **Tool Results**: Must be in specific format with `type: "tool_result"`
7. **Conversation State**: Tools can only be used if request includes tool definitions
8. **Rate Limits**: Implement exponential backoff for 429 responses

---

## Success Criteria

- [ ] All basic Claudio API calls work through adapter
- [ ] Tool execution cycle completes
- [ ] Streaming produces events at same pace as non-streaming
- [ ] Errors are caught and handled appropriately
- [ ] Agent memory maintains conversation history
- [ ] All tests pass
- [ ] Documentation is complete
- [ ] No performance degradation vs direct Claudio use

