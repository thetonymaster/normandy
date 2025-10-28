# Normandy Examples

This directory contains example applications demonstrating Normandy's capabilities.

## Available Examples

### 1. Customer Support Application

**Location**: `customer_support_app/`

A production-ready customer support system showcasing:
- Multi-agent coordination with 4 specialized agents
- Custom tools implementing the `BaseTool` protocol
- ETS-backed data stores
- OTP supervision tree
- Interactive CLI and programmatic API
- Session management with conversation history

**[View Full Documentation](./customer_support_app/README.md)**

**Quick Start**:
```bash
cd customer_support_app
mix deps.get
export ANTHROPIC_API_KEY="your-key"
iex -S mix
```

Then run:
```elixir
CustomerSupport.CLI.start()
```

## Phoenix LiveView Integration

While we don't have a complete Phoenix example yet, here's how to integrate Normandy with Phoenix LiveView:

### Setup

1. Add Normandy to your Phoenix app's `mix.exs`:

```elixir
def deps do
  [
    {:normandy, "~> 0.1.0"},
    {:claudio, "~> 0.1.1"},
    # ... other phoenix deps
  ]
end
```

2. Configure the JSON adapter in `config/config.exs`:

```elixir
config :normandy,
  adapter: Poison  # or Jason
```

### Create a Chatbot LiveView

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  alias MyApp.ChatAgent

  @impl true
  def mount(_params, _session, socket) do
    # Initialize agent on mount
    {:ok, agent} = ChatAgent.new(
      client: create_llm_client()
    )

    {:ok, assign(socket,
      agent: agent,
      messages: [],
      input: ""
    )}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    # Add user message
    messages = socket.assigns.messages ++ [%{role: :user, content: message}]

    # Get agent response
    {updated_agent, response} = ChatAgent.run(socket.assigns.agent, message)
    response_text = extract_text(response)

    # Add assistant response
    messages = messages ++ [%{role: :assistant, content: response_text}]

    {:noreply, assign(socket,
      agent: updated_agent,
      messages: messages,
      input: ""
    )}
  end

  defp create_llm_client do
    %Normandy.LLM.ClaudioAdapter{
      api_key: System.get_env("ANTHROPIC_API_KEY"),
      options: %{timeout: 60_000}
    }
  end

  defp extract_text(response) when is_binary(response), do: response
  defp extract_text(%{chat_message: text}), do: text
  defp extract_text(_), do: "Error processing response"
end
```

### Template

```heex
<div class="chat-container">
  <div class="messages">
    <%= for message <- @messages do %>
      <div class={"message message-#{message.role}"}>
        <strong><%= if message.role == :user, do: "You", else: "Assistant" %>:</strong>
        <%= message.content %>
      </div>
    <% end %>
  </div>

  <form phx-submit="send_message">
    <input
      type="text"
      name="message"
      value={@input}
      placeholder="Type your message..."
      autocomplete="off"
    />
    <button type="submit">Send</button>
  </form>
</div>
```

### With Streaming Responses

For streaming token-by-token (when implemented in Normandy):

```elixir
@impl true
def handle_event("send_message", %{"message" => message}, socket) do
  # Send async message
  pid = self()

  Task.start(fn ->
    ChatAgent.stream(socket.assigns.agent, message, fn chunk ->
      send(pid, {:agent_chunk, chunk})
    end)
  end)

  {:noreply, assign(socket, streaming: true, current_response: "")}
end

@impl true
def handle_info({:agent_chunk, chunk}, socket) do
  current = socket.assigns.current_response <> chunk
  {:noreply, assign(socket, current_response: current)}
end
```

## Notes on Mix.install Examples

**Important**: Examples using `Mix.install` (like standalone `.exs` scripts) have limitations:

- **Protocol consolidation**: Protocols are consolidated before your code runs, preventing custom tool implementations
- **No compile-time guarantees**: Can't catch errors until runtime
- **Limited for production**: Better for quick experiments only

For production applications, always use proper Mix projects like `customer_support_app`.

## Contributing Examples

When adding new examples:

1. Create a full Mix project (not Mix.install scripts)
2. Include comprehensive README with setup instructions
3. Add config files for JSON adapter
4. Provide both CLI and programmatic usage examples
5. Include error handling and logging
6. Document architecture and key design decisions

