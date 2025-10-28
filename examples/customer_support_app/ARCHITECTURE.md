# Architecture Documentation

## Overview

The Customer Support Application is a production-ready demonstration of Normandy's capabilities, showcasing a multi-agent AI system with proper OTP design patterns, fault tolerance, and clean separation of concerns.

## System Components

### 1. Application Layer

**Module**: `CustomerSupport.Application`

The OTP Application entry point that starts and supervises all components.

```elixir
Supervisor Tree:
├── OrderStore (GenServer)
├── TicketStore (GenServer)
├── KnowledgeBase (GenServer)
└── ChatSession (GenServer)
```

**Supervision Strategy**: `:one_for_one`

If any child process crashes, only that process is restarted. This provides isolation between components while maintaining system availability.

### 2. Data Layer

#### OrderStore

- **Type**: GenServer with ETS table
- **Purpose**: Persistent order storage and retrieval
- **Table**: `:orders` (named_table, set, public, read_concurrency: true)
- **Data**: Pre-seeded with 4 sample orders
- **Operations**:
  - `get_order/1` - Retrieve order by ID
  - `update_order_status/2` - Update order status
  - `list_orders/0` - List all orders

#### TicketStore

- **Type**: GenServer with ETS table
- **Purpose**: Support ticket management
- **Table**: `:tickets` (named_table, set, public, read_concurrency: true)
- **Operations**:
  - `create_ticket/1` - Create new support ticket
  - `get_ticket/1` - Retrieve ticket by ID
  - `update_ticket_status/2` - Update ticket status
  - `list_tickets/1` - List tickets with optional status filter

#### KnowledgeBase

- **Type**: GenServer with ETS table
- **Purpose**: FAQ and documentation search
- **Table**: `:knowledge_base` (named_table, set, public, read_concurrency: true)
- **Data**: Pre-seeded with 8 knowledge base articles
- **Operations**:
  - `search/2` - Full-text search with category filtering
  - `get_article/1` - Retrieve specific article
- **Search Algorithm**:
  - Keyword matching in title, content, and tags
  - Relevance scoring (title matches weighted higher)
  - Results sorted by relevance

### 3. Tools Layer

All tools implement the `Normandy.Tools.BaseTool` protocol:

```elixir
defprotocol Normandy.Tools.BaseTool do
  def tool_name(struct())
  def tool_description(struct())
  def input_schema(struct())
  def run(struct())
end
```

#### OrderLookupTool

- **Struct Fields**: `order_id`
- **Dependencies**: `CustomerSupport.DataStore.OrderStore`
- **Returns**: Formatted order details with tracking and delivery info
- **Error Handling**: Returns user-friendly error messages for not found or system errors

#### KnowledgeBaseTool

- **Struct Fields**: `query`, `category` (optional)
- **Dependencies**: `CustomerSupport.DataStore.KnowledgeBase`
- **Returns**: Top 3 most relevant articles
- **Search**: Full-text search with optional category filtering

#### TicketCreationTool

- **Struct Fields**: `title`, `description`, `category`, `priority`, `customer_email`
- **Dependencies**: `CustomerSupport.DataStore.TicketStore`
- **Returns**: Ticket ID and confirmation with SLA timeline
- **SLA Times**:
  - Urgent: 1 hour
  - High: 4 hours
  - Medium: 24 hours
  - Low: 48 hours

#### RefundProcessorTool

- **Struct Fields**: `order_id`, `reason`, `amount` (optional)
- **Dependencies**: `CustomerSupport.DataStore.OrderStore`
- **Validation**:
  - Order exists
  - Order not already refunded/cancelled
  - Within 30-day refund window
  - Refund amount <= order total
- **Returns**: Refund ID and processing timeline

### 4. Agents Layer

All agents use the Normandy DSL:

```elixir
defmodule MyAgent do
  use Normandy.DSL.Agent

  agent do
    model("claude-3-5-sonnet-20241022")
    temperature(0.7)
    background("...")
    steps("...")
    output_instructions("...")
    tool(MyTool)
  end
end
```

#### GreeterAgent

- **Temperature**: 0.7 (balanced creativity and consistency)
- **Tools**: KnowledgeBaseTool
- **Purpose**: Initial triage and query classification
- **Classification Logic**:
  - Keywords: "order", "shipping", "track" → `:order`
  - Keywords: "not working", "broken", "technical" → `:technical`
  - Keywords: "refund", "payment", "billing" → `:billing`
  - Default → `:general`

#### OrderSupportAgent

- **Temperature**: 0.6 (slightly more consistent)
- **Tools**: OrderLookupTool, KnowledgeBaseTool
- **Purpose**: Order tracking, shipping inquiries
- **Behavior**: Proactively looks up orders when ID mentioned

#### TechnicalSupportAgent

- **Temperature**: 0.5 (more consistent for troubleshooting)
- **Tools**: KnowledgeBaseTool, TicketCreationTool, RefundProcessorTool, OrderLookupTool
- **Purpose**: Product troubleshooting and technical issues
- **Workflow**: Troubleshooting → Ticket creation or refund if unresolved

#### BillingSupportAgent

- **Temperature**: 0.4 (most consistent for financial transactions)
- **Tools**: RefundProcessorTool, OrderLookupTool, KnowledgeBaseTool, TicketCreationTool
- **Purpose**: Refunds, billing disputes, payment issues
- **Workflow**: Verify eligibility → Process refund → Create ticket for disputes

### 5. Session Management Layer

**Module**: `CustomerSupport.ChatSession`

- **Type**: GenServer with ETS table
- **Purpose**: Manage customer support sessions
- **Table**: `:chat_sessions` (named_table, set, public, read_concurrency: true)

#### Session Structure

```elixir
%{
  session_id: "session-123456",
  created_at: ~U[2025-10-26 12:00:00Z],
  current_agent: :order_support,
  agents: %{
    greeter: %BaseAgentConfig{...},
    order_support: %BaseAgentConfig{...}
  },
  history: [
    %{timestamp: ~U[...], role: :user, content: "..."},
    %{timestamp: ~U[...], role: :assistant, agent: :greeter, content: "..."}
  ],
  client: %Normandy.LLM.ClaudioAdapter{...}
}
```

#### Agent Routing Logic

1. **First message**: Always routes to GreeterAgent
2. **Subsequent messages**:
   - If currently with specialist and not changing topics → Stay with current agent
   - If changing topics (keywords: "different question", "something else") → Re-classify
   - Use GreeterAgent's classification logic to determine appropriate specialist

#### Message Processing Flow

```
User Input
    ↓
Determine Agent (routing logic)
    ↓
Get/Create Agent Instance
    ↓
Run Agent (with try/rescue)
    ↓
Extract Response Text
    ↓
Update Session (agent state + history)
    ↓
Save to ETS
    ↓
Return Response
```

### 6. API Layer

**Module**: `CustomerSupport`

Public API functions:
- `create_session/0` - Creates new session, returns `{:ok, session_id}`
- `send_message/2` - Sends message to session, returns `{:ok, response}`
- `get_history/1` - Retrieves conversation history
- `end_session/1` - Terminates session and cleans up

### 7. CLI Layer

**Module**: `CustomerSupport.CLI`

Interactive command-line interface with:
- Colored output using ANSI codes
- Commands: /help, /history, /stats, /clear, /quit
- Real-time "thinking..." indicator
- Formatted conversation display
- Session statistics

## Data Flow

### Creating a Session

```
User calls create_session()
    ↓
ChatSession.create_session()
    ↓
Generate session_id
    ↓
Create LLM client (ClaudioAdapter)
    ↓
Initialize GreeterAgent
    ↓
Store session in ETS
    ↓
Return {:ok, session_id}
```

### Processing a Message

```
User sends message
    ↓
ChatSession receives message
    ↓
Load session from ETS
    ↓
Add user message to history
    ↓
Determine appropriate agent (routing)
    ↓
Get or create agent instance
    ↓
Agent processes message
    ├── Parse user intent
    ├── Call tools as needed
    │   ├── Tool validates input
    │   ├── Tool queries data store
    │   └── Tool returns formatted result
    └── Generate response
    ↓
Update agent state in session
    ↓
Add assistant response to history
    ↓
Save session to ETS
    ↓
Return response to user
```

### Tool Execution

```
Agent decides to use tool
    ↓
Agent calls tool with parameters
    ↓
Tool struct created
    ↓
Protocol implementation called
    ├── tool_name/1 - Identifies tool
    ├── tool_description/1 - Describes purpose
    ├── input_schema/1 - Validates structure
    └── run/1 - Executes logic
        ↓
    Tool accesses data store
        ↓
    Data store queries ETS
        ↓
    Results formatted
        ↓
    {:ok, result} or {:error, reason}
    ↓
Tool result returned to agent
    ↓
Agent incorporates result in response
```

## Error Handling

### Agent Execution Errors

```elixir
try do
  AgentModule.run(agent, message)
rescue
  error ->
    Logger.error("Agent error: #{inspect(error)}")
    {:error, error}
end
```

User receives: "I'm having trouble processing your request. Please try again."

### Tool Execution Errors

Tools return `{:error, reason}` which agents handle gracefully:
- Not found errors → "Order #{id} not found. Please verify the order ID."
- Validation errors → "Refund not allowed: Order is outside 30-day refund window"
- System errors → "Failed to retrieve order: #{inspect(reason)}"

### Data Store Failures

If a data store GenServer crashes:
- Supervisor restarts it automatically (one_for_one)
- ETS table is recreated with sample data
- Ongoing operations may fail but system remains available
- No cascade failures to other components

## Concurrency & Performance

### ETS Tables

- **Concurrency**: `read_concurrency: true` for all tables
- **Access**: Public tables allow direct reads without GenServer bottleneck
- **Writes**: Go through GenServer for consistency

### Agent Instances

- Each session maintains its own agent instances
- Agent state (conversation memory) is session-specific
- Multiple sessions can run concurrently without interference

### Session Isolation

- Each session stored independently in ETS
- Session operations are synchronous (GenServer.call)
- Timeout: 60 seconds for message processing

## Configuration

### LLM Client

```elixir
%Normandy.LLM.ClaudioAdapter{
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  options: %{
    timeout: 60_000,
    enable_caching: true
  }
}
```

### Agent Temperature Settings

- **Greeter**: 0.7 (balanced, needs creativity for classification)
- **Order Support**: 0.6 (consistent with slight flexibility)
- **Technical Support**: 0.5 (consistent troubleshooting steps)
- **Billing Support**: 0.4 (most consistent for financial operations)

## Scaling Considerations

### Current Design (Single Node)

- ETS-backed storage (in-memory, single-node)
- GenServer-based session management
- Suitable for: Development, testing, small deployments

### Production Scaling

1. **Multi-Node Deployment**:
   - Replace ETS with distributed storage (Redis/PostgreSQL)
   - Use Phoenix PubSub for session coordination
   - Implement session stickiness or distributed session storage

2. **Performance Optimization**:
   - Agent connection pooling
   - Response caching for common queries
   - Async tool execution where possible

3. **Monitoring**:
   - Add Telemetry events for:
     - Message processing latency
     - Tool execution times
     - Agent switching frequency
     - Error rates by type

## Security Considerations

### Current Implementation

- API key loaded from environment variable
- No authentication/authorization (demo purposes)
- Session IDs are random but predictable

### Production Requirements

1. **Authentication**: User identity verification
2. **Authorization**: Role-based access control
3. **Session Security**: Cryptographically secure session IDs
4. **API Key Management**: Secret storage (Vault, AWS Secrets Manager)
5. **Rate Limiting**: Per-user/session limits
6. **Input Validation**: Sanitize all user inputs
7. **Audit Logging**: Track all operations for compliance

## Testing Strategy

### Unit Tests

- Data store operations (CRUD)
- Tool input validation and execution
- Agent classification logic
- Session routing logic

### Integration Tests

- Full message flow from input to response
- Agent coordination and tool calling
- Error recovery scenarios
- Multi-turn conversations

### Load Tests

- Concurrent session handling
- Message throughput
- Memory usage under load
- ETS table performance

## Observability

### Logging

Current implementation logs:
- Application startup
- Session creation/termination
- Agent execution errors
- Data store initialization

Production additions:
- Structured logging (JSON)
- Log levels (debug/info/warn/error)
- Request tracing with correlation IDs
- Performance metrics

### Monitoring Metrics

Recommended metrics:
- Active sessions count
- Messages processed per second
- Average response time
- Tool execution times
- Error rate by type
- Agent distribution (which agents are most used)

## Future Enhancements

1. **Streaming Responses**: Support for token-by-token streaming
2. **Multi-Modal**: Image support for product issues
3. **Sentiment Analysis**: Track customer satisfaction
4. **Escalation Workflow**: Human handoff for complex issues
5. **Analytics Dashboard**: Session statistics and insights
6. **Custom Tool Registry**: Dynamic tool loading
7. **Agent Hot-Reload**: Update agent behavior without restart
