# Customer Support Application

A production-ready customer support system built with [Normandy](https://github.com/thetonymaster/normandy), demonstrating multi-agent AI coordination, tool integration, and OTP best practices.

## Overview

This application showcases a complete AI-powered customer support system with:

- **4 Specialized AI Agents** for different support scenarios
- **4 Custom Tools** for data access and operations
- **ETS-backed Data Stores** for orders, tickets, and knowledge base
- **Session Management** with conversation history
- **OTP Supervision Tree** for fault tolerance
- **Interactive CLI** for testing and demonstration

## Architecture

```
┌─────────────────────────────────────────────────────┐
│           Customer Support Application               │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐│
│  │  Greeter    │  │Order Support │  │  Technical  ││
│  │   Agent     │  │    Agent     │  │   Support   ││
│  └─────────────┘  └──────────────┘  └─────────────┘│
│                                                       │
│  ┌─────────────┐                                     │
│  │  Billing    │    AI Agents Layer                  │
│  │  Support    │    (Normandy DSL)                   │
│  └─────────────┘                                     │
│                                                       │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │   Order     │  │ Knowledge   │  │   Ticket    │ │
│  │   Lookup    │  │    Base     │  │  Creation   │ │
│  └─────────────┘  └─────────────┘  └─────────────┘ │
│                                                       │
│  ┌─────────────┐          Tools Layer                │
│  │   Refund    │          (BaseTool Protocol)        │
│  │  Processor  │                                     │
│  └─────────────┘                                     │
│                                                       │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │
│  │ OrderStore  │  │ TicketStore │  │ Knowledge   │ │
│  │ (GenServer) │  │ (GenServer) │  │    Base     │ │
│  └─────────────┘  └─────────────┘  │ (GenServer) │ │
│                                     └─────────────┘ │
│           Data Layer (ETS-backed)                    │
│                                                       │
├─────────────────────────────────────────────────────┤
│                                                       │
│  ┌──────────────────────────────────────────────┐   │
│  │         ChatSession (GenServer)               │   │
│  │  - Session management                         │   │
│  │  - Agent routing                              │   │
│  │  - Conversation history                       │   │
│  └──────────────────────────────────────────────┘   │
│                                                       │
└─────────────────────────────────────────────────────┘
```

## Features

### Multi-Agent System

- **GreeterAgent**: Initial triage and query classification
- **OrderSupportAgent**: Order tracking, shipping, and delivery inquiries
- **TechnicalSupportAgent**: Product troubleshooting and technical support
- **BillingSupportAgent**: Refunds, payments, and billing issues

### Tool Integration

All tools implement the `Normandy.Tools.BaseTool` protocol:

- **OrderLookupTool**: Retrieve order details and tracking information
- **KnowledgeBaseTool**: Search FAQs and documentation
- **TicketCreationTool**: Create support tickets for follow-up
- **RefundProcessorTool**: Process refund requests with eligibility checks

### Data Stores

ETS-backed GenServers with sample data:

- **OrderStore**: 4 sample orders with various statuses
- **TicketStore**: Support ticket management
- **KnowledgeBase**: 8 pre-loaded FAQ articles

### Session Management

- Persistent conversation history
- Automatic agent routing based on query type
- Multi-turn conversations with context retention
- Session statistics and history viewing

## Installation

### Prerequisites

- Elixir 1.19+ (or 1.15+ with adjustments)
- Erlang/OTP 25+
- Anthropic API key

### Setup

1. **Clone the repository** (if not already in it):

```bash
cd normandy/examples/customer_support_app
```

2. **Install dependencies**:

```bash
mix deps.get
```

3. **Set your API key**:

```bash
export ANTHROPIC_API_KEY="your-api-key-here"
```

4. **Compile the application**:

```bash
mix compile
```

**Note**: The application requires a config file to set the JSON adapter. The config files are already included in the `config/` directory.

## Usage

### Interactive CLI

Start the interactive customer support CLI:

```bash
iex -S mix
```

Then in the IEx console:

```elixir
CustomerSupport.CLI.start()
```

Available CLI commands:
- `/help` - Show help message
- `/history` - View conversation history
- `/stats` - Show session statistics
- `/clear` - Clear screen
- `/quit` - End session

### Programmatic Usage

```elixir
# Ensure application is started
{:ok, _} = Application.ensure_all_started(:customer_support)

# Create a session
{:ok, session_id} = CustomerSupport.create_session()

# Send messages
{:ok, response} = CustomerSupport.send_message(session_id, "I need help with order ORD-12345")
IO.puts(response)

{:ok, response} = CustomerSupport.send_message(session_id, "When will it arrive?")
IO.puts(response)

# Get conversation history
{:ok, history} = CustomerSupport.get_history(session_id)

# End session
CustomerSupport.end_session(session_id)
```

## Example Interactions

### Order Tracking

```
You: I need to check on order ORD-12345
Agent: I'll look up that order for you right away!

Order Details:
- Order ID: ORD-12345
- Status: shipped
- Items: Wireless Headphones (x1), USB-C Cable (x2)
- Total: $105.97
- Tracking: TRK-ABC123
- Estimated Delivery: 2025-10-29

Your order is on its way! Is there anything else I can help you with?
```

### Technical Support

```
You: My wireless headphones aren't connecting
Agent: I'd be happy to help you troubleshoot your wireless headphones. Let's try these steps:

1. Check that the headphones are fully charged
2. Turn Bluetooth off and on on your device
3. Forget the device in Bluetooth settings, then re-pair
4. Try resetting the headphones by holding the power button for 10 seconds

Have you tried these steps?
```

### Refund Request

```
You: I'd like to request a refund for order ORD-12345
Agent: I understand you'd like a refund. Let me check your order eligibility...

Order found! To process your refund, could you tell me the reason?
- Defective product
- Wrong item received
- Not as described
- Changed mind
- Other

You: The product is defective
Agent: I'm sorry to hear that. Let me process that refund for you now.

Refund Initiated Successfully
Refund ID: REF-12345
Order ID: ORD-12345
Amount: $105.97
Reason: Defective product

The refund will be processed within 3-5 business days...
```

## Configuration

### Environment Variables

- `ANTHROPIC_API_KEY` - Required for Claude API access

### Application Config

You can customize agent behavior in each agent module:

```elixir
# lib/customer_support/agents/greeter_agent.ex
agent do
  model("claude-3-5-sonnet-20241022")
  temperature(0.7)  # Adjust for creativity vs consistency
  # ...
end
```

## Development

### Project Structure

```
lib/
├── customer_support/
│   ├── agents/              # AI Agents using Normandy DSL
│   │   ├── greeter_agent.ex
│   │   ├── order_support_agent.ex
│   │   ├── technical_support_agent.ex
│   │   └── billing_support_agent.ex
│   ├── tools/               # Tools implementing BaseTool protocol
│   │   ├── order_lookup_tool.ex
│   │   ├── knowledge_base_tool.ex
│   │   ├── ticket_creation_tool.ex
│   │   └── refund_processor_tool.ex
│   ├── data_store/          # ETS-backed data stores
│   │   ├── order_store.ex
│   │   ├── ticket_store.ex
│   │   └── knowledge_base.ex
│   ├── application.ex       # OTP Application
│   ├── chat_session.ex      # Session management
│   └── cli.ex               # Interactive CLI
└── customer_support.ex      # Public API
```

### Adding New Agents

1. Create agent module using Normandy DSL
2. Register tools with `tool(YourTool)`
3. Add agent to `ChatSession.create_agent/2`
4. Update routing logic in `ChatSession.determine_agent/2`

### Adding New Tools

1. Define struct with required parameters
2. Implement `Normandy.Tools.BaseTool` protocol
3. Implement `tool_name/1`, `tool_description/1`, `input_schema/1`, `run/1`
4. Register tool in relevant agents

## Testing

Run tests:

```bash
mix test
```

## Production Considerations

This is a demonstration application. For production use, consider:

1. **Persistent Storage**: Replace ETS with PostgreSQL/Redis
2. **Authentication**: Add user authentication and authorization
3. **Rate Limiting**: Implement rate limiting for API calls
4. **Monitoring**: Add Telemetry for observability
5. **Error Handling**: Enhanced error recovery and logging
6. **Scaling**: Use Phoenix PubSub for distributed sessions
7. **Testing**: Add comprehensive unit and integration tests

## License

This example application is part of the Normandy project (MIT License).

