# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Normandy is an Elixir library for building AI agents with structured schemas, validation, and LLM integration. It provides a type-safe approach to defining agent inputs/outputs using JSON schemas and supports conversational memory management.

## Common Commands

### Development
- `mix compile` - Compile the project
- `mix format` - Format code according to .formatter.exs
- `mix test` - Run all tests
- `mix test test/path/to/test.exs` - Run a specific test file
- `mix test test/path/to/test.exs:42` - Run a specific test at line 42

### Dependencies
- `mix deps.get` - Fetch dependencies
- `mix deps.compile` - Compile dependencies

### Console
- `iex -S mix` - Start interactive Elixir shell with project loaded

## Architecture

### Schema System (Core Foundation)

The schema system is Normandy's foundation, heavily inspired by Ecto but adapted for AI agent I/O schemas:

- **`Normandy.Schema`** - Macro-based DSL for defining structs with JSON schema generation
  - `schema do ... end` - Basic schema definition
  - `io_schema "description" do ... end` - I/O schemas with BaseIOSchema protocol implementation
  - `field/3` - Define fields with types and options (`:description`, `:required`, `:default`)
  - Automatically generates JSON Schema specifications via `__specification__/0`

- **`Normandy.Type`** - Type system with casting, dumping, and loading
  - Base types: `:integer`, `:float`, `:boolean`, `:string`, `:map`, `:date`, `:time`, `:binary`, `:any`, `:struct`
  - Composite types: `{:array, type}`, `{:map, type}`
  - Custom types via `Normandy.Type` behaviour (requires `type/0`, `cast/1`, `dump/1`, `load/1` callbacks)
  - Parameterized types via `Normandy.ParameterizedType`

- **`Normandy.Validate`** - Changeset-like validation for schemas
  - `cast/4` - Cast params into schema types
  - `validate_required/2`, `validate_format/3`, `validate_inclusion/3`, `validate_length/3`, `validate_number/3`, etc.
  - Returns `%Validate{}` struct with errors, changes, and validation state

### Agent System

- **`Normandy.Agents.BaseAgent`** - Core agent implementation
  - `init/1` - Initialize agent with `BaseAgentConfig` (requires `:client`, `:model`, `:temperature`)
  - `run/2` - Execute agent turn with optional user input, returns `{updated_config, response}`
  - `get_response/2` - Get LLM response using prompt specification
  - `reset_memory/1` - Reset conversation to initial state
  - Context provider management: `register_context_provider/3`, `get_context_provider/2`, `delete_context_provider/2`

- **`Normandy.Agents.BaseAgentConfig`** - Agent state container
  - Stores: input/output schemas, memory, prompt specification, LLM client/model, temperature, max_tokens

- **`Normandy.Agents.Model`** - Protocol for LLM client implementations
  - Requires: `converse/6` and `completitions/6` implementations
  - Clients must implement this protocol (see Claudio integration in dependencies)

### Memory & Messages

- **`Normandy.Components.AgentMemory`** - Conversation history management
  - `new_memory/1` - Create memory with optional max_messages limit
  - `add_message/3` - Add user/assistant message to history
  - `initialize_turn/1` - Start new conversation turn (generates UUID)
  - `history/1` - Get formatted message history for LLM
  - `dump/1` and `load/1` - Serialize/deserialize memory state
  - `delete_turn/2` - Remove specific conversation turn

- **`Normandy.Components.Message`** - Message struct with `:turn_id`, `:role`, `:content`

### Prompt System

- **`Normandy.Components.SystemPromptGenerator`** - Generates system prompts
  - Takes `PromptSpecification` and builds structured prompt with sections:
    - "IDENTITY and PURPOSE" (background)
    - "INTERNAL ASSISTANT STEPS" (steps)
    - "OUTPUT INSTRUCTIONS" (output_instructions + auto-added JSON schema requirement)
    - "EXTRA INFORMATION AND CONTEXT" (from context providers)

- **`Normandy.Components.PromptSpecification`** - Defines prompt structure
  - Fields: `:background`, `:steps`, `:output_instructions`, `:context_providers`

- **`Normandy.Components.ContextProvider`** - Protocol for providing dynamic context
  - Used to inject runtime information into prompts (e.g., current time, user data)

### I/O Schema Protocol

- **`Normandy.Components.BaseIOSchema`** - Protocol for agent I/O serialization
  - Auto-implemented for `io_schema` definitions
  - Methods: `to_json/1`, `get_schema/1`, `__str__/1`, `__rich__/1`
  - Uses adapter from `:normandy` app config (`:adapter` key, typically Poison)

## Key Patterns

### Defining Agent I/O Schemas

```elixir
defmodule MyInputSchema do
  use Normandy.Schema

  io_schema "Input for my agent" do
    field :query, :string, description: "User query", required: true
    field :max_results, :integer, description: "Max results", default: 10
  end
end
```

### Agent Workflow

1. Define input/output schemas using `io_schema`
2. Create `BaseAgentConfig` with schemas, LLM client, and prompt specification
3. Initialize agent with `BaseAgent.init/1`
4. Run conversation turns with `BaseAgent.run/2`
5. Agent manages memory automatically, serializing I/O schemas to JSON

### Validation Flow

1. Cast params with `Validate.cast/4` specifying permitted fields
2. Chain validations: `validate_required/2`, `validate_format/3`, etc.
3. Check `changeset.valid?` or use `apply_action/2` for error handling
4. Apply changes with `apply_changes/1` or `apply_action!/2`

## Configuration

- `config/config.exs` - Imports environment-specific config
- `config/dev.exs` and `config/test.exs` - Environment configs
- Application config requires `:adapter` (JSON encoder/decoder, e.g., Poison)
- `consolidate_protocols: false` in test environment for faster compilation

## Dependencies

- **Claudio** - LLM client library (private git dependency)
- **Poison** - JSON encoding/decoding
- **elixir_uuid** - UUID generation for conversation turns

## Notes

- Protocol consolidation disabled in test env (`consolidate_protocols: Mix.env() != :test`)
- Test support files in `test/support/` (included via `elixirc_paths/1` in mix.exs)
- Metadata tracking via `Normandy.Metadata` struct in schemas
