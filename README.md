# Normandy

> Build production-ready AI agents in Elixir — structured schemas, tool calling, multi-agent coordination, streaming, and distributed sessions, with first-class Anthropic Claude support.

[![Hex.pm](https://img.shields.io/hexpm/v/normandy.svg)](https://hex.pm/packages/normandy)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/normandy)
[![CI](https://github.com/thetonymaster/normandy/actions/workflows/ci.yml/badge.svg)](https://github.com/thetonymaster/normandy/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/hexpm/l/normandy.svg)](https://github.com/thetonymaster/normandy/blob/main/LICENSE)

**Normandy** is an Elixir framework for building reliable LLM agents on the BEAM. It gives you type-safe input/output schemas with automatic JSON Schema generation, tool/function calling, conversational memory, and OTP-native primitives for multi-agent coordination and distributed, fault-tolerant sessions. It ships with a built-in adapter for [Anthropic Claude](https://www.anthropic.com) and a clean protocol for any other LLM provider.

## Features

- **🧠 Agent system** — conversational agents with memory, state, and turn-based history.
- **📋 Schema DSL** — typed, validated structs with JSON Schema generation (nested schemas, `anyOf`/`oneOf`/`allOf`, conditional `if`/`then`/`else`, virtual fields, introspection).
- **🔧 Tool calling** — LLM tool/function calling with automatic execution loops.
- **🤝 Multi-agent coordination** — reactive patterns (`race`/`all`/`some`), agent pools, and supervised agent processes.
- **🌐 Distributed sessions** — single-node to multi-node, fault-tolerant sessions across Tiers 0/1/2 (in-memory/ETS, Postgres, Mnesia, Redis) with eager resume on node loss.
- **🛡️ Guardrails** — input/output admission control with fail-open/closed policies and semantic scope checks.
- **🌊 Streaming** — real-time response streaming with callback-based event processing.
- **💰 Prompt caching** — up to 90% cost reduction via automatic Anthropic prompt caching.
- **🔄 Resilience** — built-in retry (exponential backoff + jitter) and circuit breaker patterns.
- **📦 Batch processing** — concurrent processing of many inputs with progress tracking.
- **📏 Context management** — token counting, automatic truncation, and LLM-based summarization.
- **🔌 Protocol support** — interoperate via Model Context Protocol (MCP) and Agent-to-Agent (A2A).
- **📊 Observability** — Telemetry events, structured lifecycle logging, and OpenTelemetry-compatible spans.
- **🎯 Type safety** — comprehensive type system with Dialyzer support, backed by 900+ tests including property-based testing.

## Installation

Add `normandy` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:normandy, "~> 1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

Define structured data, then run an agent against Anthropic Claude:

```elixir
# 1. Configure an LLM client (built-in Anthropic Claude adapter)
client = %Normandy.LLM.ClaudioAdapter{
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  options: %{enable_caching: true}
}

# 2. Initialize an agent
agent =
  Normandy.Agents.BaseAgent.init(%{
    client: client,
    model: "claude-sonnet-4-6",
    temperature: 0.7
  })

# 3. Run a turn
{agent, response} =
  Normandy.Agents.BaseAgent.run(agent, %{
    chat_message: "Explain Elixir's actor model in one sentence."
  })
```

Defining a typed schema is just as direct:

```elixir
defmodule User do
  use Normandy.Schema

  io_schema "User profile" do
    field(:name, :string, description: "Full name", required: true)
    field(:age, :integer, description: "Age", minimum: 0, maximum: 150)
  end
end

# Export as JSON Schema for LLM prompts / structured output
schema = User.get_json_schema()
```

Bring your own LLM by implementing the `Normandy.Agents.Model` protocol — Claude is supported out of the box, but nothing is hard-wired to it.

## Documentation

Full API reference and guides are published on HexDocs:

- **📚 [API documentation](https://hexdocs.pm/normandy)** — every module, grouped by Core, Agents, DSL, Coordination, Tools, Context Management, Resilience, Guardrails, MCP, A2A, and LLM Adapters.
- **🌐 [Distributed sessions guide](docs/guides/distributed_sessions.md)** — Tiers 0/1/2, durable stores, and multi-node setup.
- **📝 [CHANGELOG](CHANGELOG.md)** — release notes and migration guidance.
- **🗺️ [ROADMAP](ROADMAP.md)** — phased development history and direction.

Generate the docs locally with `mix docs` and open `doc/index.html`.

## Development

```bash
mix test            # run the default suite (integration tests skipped)
mix test --cover    # run with coverage
mix dialyzer        # static type analysis
mix format          # format code
```

Run the live-API integration suite with an Anthropic key:

```bash
export ANTHROPIC_API_KEY="your-api-key"
mix test --include integration --include normandy_integration
```

## Contributing

Contributions are welcome — please open an issue or submit a pull request.

## License

Released under the [MIT License](LICENSE).

## Acknowledgments

The schema system is inspired by [Ecto](https://github.com/elixir-ecto/ecto)'s approach to data definition, validation, and changesets.

---

**Made with Elixir** 💜
