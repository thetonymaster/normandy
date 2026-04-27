# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Tool loop refactor (`BaseAgent`)**: extracted the per-tool-call body of
  `execute_tool_loop/2` and `execute_streaming_tool_loop/3` into the private
  helpers `execute_one_tool_call/2` and `execute_one_streaming_tool_call/2`.
  Pure refactor — behaviour, ordering, and process semantics are identical to
  the previous inline `Enum.map` closures. Sets up a follow-up change to swap
  `Enum.map` for an opt-in bounded parallel runner (per-agent
  `max_tool_concurrency`) without churning the closure body again.

## [0.4.0] - 2026-04-25

### Added

- **Multimodal Content Blocks**: Image and document support for agent messages
  - `Normandy.Components.ContentBlock.{Text, Image, Document}` framework-neutral
    block types with per-module `to_claudio/1` emitting Anthropic wire shapes
  - `ClaudioAdapter.add_single_message/3` opportunistically dispatches to
    Claudio's named helpers for the three wrapped shapes (base64 image+text,
    URL image+text, document+text); other shapes (multi-block, reversed,
    image-alone, pre-shaped maps with `cache_control`) fall through to a
    raw-list `add_message/3`
  - `Normandy.Components.Message.content` widened from `:struct` to `:any` with
    extended `@type t` covering `String.t() | struct() | [struct()]`
  - Token accounting in `WindowManager`, `TokenCounter`, and `Summarizer` now
    handles list content (image blocks ~1600 tokens, documents ~3000) instead
    of silently zero-counting them

- **Guardrails**: First-class content-level constraint layer for agent I/O,
  composable across input and output stages
  - `Normandy.Guardrails` runner with short-circuit semantics
  - `Normandy.Guardrails.Guard` behaviour for custom guards
  - `Normandy.Guardrails.ViolationError` raised on input violations
  - Built-in guards: `MaxLength`, `ForbiddenSubstrings`, `RegexGuard`
    (`:deny`/`:require` modes), `RequiredFields`
  - `BaseAgent` integration via new `:input_guardrails` / `:output_guardrails`
    config keys (input violations halt, output violations log and continue,
    mirroring `ValidationMiddleware`)
  - DSL macro `guardrails(:input | :output, [specs])` in `Normandy.DSL.Agent`
  - Telemetry event `[:normandy, :agent, :guardrail, :violation]` with
    `:stage`, `:agent_name`, `:guards`, and `:violations` metadata
  - Works on both non-streaming (`run/2`) and streaming paths — see the
    streaming output guardrails entry below for streaming specifics

- **Streaming Output Guardrails**: Output guardrails now run on streaming paths
  - `:accumulate` mode (default) — guards run on the final assistant text
    after the stream ends; log-and-continue on violation, matching
    non-streaming `run/2` posture
  - `:incremental` mode (opt-in) — guards run every
    `:output_guardrails_chunk_size` bytes of accumulated text plus a tail
    pass when the stream ends with unchecked bytes; on violation halts
    mid-stream, strips any in-flight `tool_use` content block, and returns
    with `:guardrail_violations` populated
  - Three signal channels on both modes: `:guardrail_violation` stream
    callback event, `:guardrail_violations` field on the returned response,
    and the existing telemetry event (metadata gains `streaming: true` and
    `mode: :accumulate | :incremental`)
  - New DSL macros inside `agent do … end`: `streaming_mode/1`,
    `streaming_chunk_size/1`
  - New `BaseAgentConfig` fields: `:output_guardrails_streaming_mode`,
    `:output_guardrails_chunk_size`

### Fixed

- **Streaming Cold-Start**: `BaseAgent.stream_response/3` and
  `stream_with_tools/3` no longer fail with `"Client does not support streaming"`
  when invoked as the first call through the `Normandy.Agents.Model` protocol.
  With protocol consolidation enabled (default in `:dev`/`:prod`), the
  consolidated impl module was not auto-loaded, so the `function_exported?/3`
  capability probe returned false. Now wraps the probe with `Code.ensure_loaded/1`
  (#9).

### Changed

- **Claudio dependency** bumped to `~> 0.4.0`. Required for streaming SSE
  events to decode with string-keyed data maps (matches the raw Anthropic
  JSON convention); earlier `keys: :atoms` decoding silently dropped
  callback dispatches in Normandy's adapter.

## [0.3.0] - 2026-04-18

### Added

- **MCP and A2A Protocol Support**: New protocols for interoperability
  - `Normandy.MCP.ToolWrapper` for wrapping Model Context Protocol (MCP) tools
  - `Normandy.MCP.Registry` for managing MCP tool collections
  - `Normandy.A2A.Server` for agent-to-agent communication
  - Support for cross-agent tool execution and discovery

- **Structured Agent Lifecycle Logging & Telemetry**: Enhanced observability
  - `Logger` calls for agent, LLM, and tool lifecycle events
  - Telemetry events for:
    - `[:normandy, :agent, :run, :start | :stop | :exception]`
    - `[:normandy, :llm, :call, :start | :stop | :exception]`
    - `[:normandy, :tool, :execute, :start | :stop | :exception]`
  - Automatic duration tracking for all operations
  - Metadata enrichment with agent names, models, and tool names
  - OpenTelemetry-friendly logging with span context correlation

- **Telemetry Metadata & Robustness**:
  - Agent names included in all telemetry metadata
  - Improved error handling in LLM adapter calls
  - Support for `Finch` connection pool in `ClaudioAdapter`

- **DSL Enhancements**:
  - Exposed `run/3` in DSL for direct streaming support
  - Improved agent definition ergonomics

#### Schema Enhancements
- **Schema-Based Tool Definition**: New `SchemaBaseTool` mixin for streamlined tool creation
  - `tool_schema` macro providing single source of truth for tool definitions
  - Automatic JSON schema generation and validation
  - ~60% reduction in boilerplate code compared to manual approach

- **Tool Registry Metadata Methods**: Enhanced introspection capabilities
  - `get_metadata/2`, `list_metadata/1`, `filter_by_required_params/2`, etc.
  - Find tools by constraints, parameter types, or required fields

- **Validation Middleware**: Automatic validation for agent inputs and outputs
  - Type-safe agent execution with path-based error messages
  - Fail-fast on invalid inputs, warn on invalid LLM outputs

### Changed

- **Calculator Tool Migration**: Migrated to schema-based approach with improved type safety
- **HTTP Client**: Added support for custom `Finch` pools in `ClaudioAdapter`
- **JSON Schema Type Format**: Schema types now use atoms (`:object`) instead of strings (`"object"`)
- **CI/CD**: Adjusted test coverage threshold to 60% and updated matrix testing

### Fixed

- **Streaming Stability**: Restored tool loop, message conversion, and event shape in streaming responses
- **Tool Loop**: Fixed unwrap of double-nested JSON in `chat_message` after tool loop completion
- **JSON Deserialization**: Return structured content blocks from tool `to_json` instead of raw strings
- **Dependency Issues**: Added default `Poison` adapter to prevent encoding errors in consuming apps
- **Logging**: Preserved DSL-defined agent names in lifecycle logs
- **Dialyzer**: Resolved various type errors and added ignore patterns for clean analysis
- **CI**: Fixed compilation warnings and intermittent test failures

### Test Coverage
- Total tests: 900+ (doctests + property tests + unit tests)
- 0 failures, 100% passing rate

## [0.2.0] - 2025-10-28

### Added

#### CI/CD Infrastructure
- **GitHub Actions Workflow**: Comprehensive CI pipeline for automated testing
  - Matrix testing across Elixir 1.15, 1.16, 1.17 and OTP 26, 27
  - Separate jobs for unit tests, integration tests, Dialyzer, and dependency audits
  - Smart caching for dependencies and PLT files
  - Conditional integration test execution with API key support
  - Documentation in `.github/workflows/README.md`

#### Examples and Documentation
- **Comprehensive Examples**: Three runnable examples demonstrating key features
  - Customer support agent with custom tools and conversational memory
  - Multi-agent research workflow with parallel execution
  - Structured data extraction with validated output schemas
  - Complete examples README with setup instructions and key concepts

- **Customer Support Example Application**: Production-ready multi-agent system
  - Four specialized agents (Greeter, Technical, Billing, Order Support)
  - Custom tools for knowledge base, order lookup, refunds, and ticket creation
  - Interactive CLI interface with session management
  - Data stores for orders, tickets, and knowledge base
  - Full application architecture documentation

#### Context Management Improvements
- **TokenCounter Test Coverage**: Comprehensive unit tests for token counting
  - 15 tests covering all TokenCounter functionality
  - Mock-based testing for unit tests
  - Integration tests for real API calls
  - Error handling and edge case coverage

- **Date/Time Context Provider**: Dynamic timestamp injection for prompts
  - `Normandy.Components.DateTimeProvider` for temporal context
  - Configurable timezone support
  - Test coverage for provider functionality

#### Development Tools
- **JSON Deserializer**: Improved JSON parsing with error handling
  - `Normandy.LLM.JsonDeserializer` for robust JSON parsing
  - Fallback mechanisms for malformed JSON
  - Integration tests for retry scenarios

### Fixed
- **TokenCounter Implementation**: Critical bug fixes for production use
  - Fixed Claudio client initialization (map format instead of keyword list)
  - Fixed agent structure access patterns (direct field access)
  - Fixed system prompt extraction (pattern matching instead of get_in/2)
  - Added comprehensive error handling for malformed agents

- **Access Protocol Issues**: Resolved struct field access errors
  - Replaced get_in/2 with pattern matching for BaseAgentConfig
  - Improved error messages for malformed agent structures

### Documentation
- Enhanced ExDoc configuration with organized module groups
- Examples directory with comprehensive usage documentation
- CI/CD workflow documentation with local testing commands
- Customer support application architecture guide

### Test Coverage
- 443 unit tests (29 doctests + 21 properties + 393 tests)
- 62 integration tests (56 API + 6 comprehensive DSL tests)
- 15 new TokenCounter unit tests
- Total: 505+ tests, all passing

## [0.1.0] - 2025-10-26

### Added

#### Declarative DSLs (Phase 8.6)
- **Agent DSL**: Define agents with declarative syntax
  - `Normandy.DSL.Agent` - `agent do ...end` blocks for agent configuration
  - Macro-based configuration for model, temperature, prompts, tools
  - Automatic initialization with `new/1` and agent execution
  - Background, steps, and output_instructions directives

- **Workflow DSL**: Compose multi-agent workflows
  - `Normandy.DSL.Workflow` - `workflow do ... end` blocks
  - Sequential execution: `step :name do ... end`
  - Parallel execution: `parallel :name do ... end`
  - Race patterns: `race :name do ... end`
  - Data flow: `input(from: :step_name)` or static values
  - Result transformation: `transform fn ... end`
  - Conditional execution: `when_result do ... end`
  - Automatic step orchestration and error handling

- **Pattern Matching Helpers**: Utilities for result tuples
  - `Normandy.Coordination.Pattern` - Ergonomic {:ok, value} | {:error, reason} handling
  - Type checking: `ok?/1`, `error?/1`
  - Value extraction: `ok!/2`, `error!/2`, `unwrap!/1`
  - Filtering lists: `filter_ok/1`, `filter_errors/1`
  - Transformations: `map_ok/2`, `map_error/2`
  - Composition: `then/2`, `find_ok/1`, `collect_ok/1`, `all_ok/1`, `all_ok_map/1`
  - Wrapping utilities: `wrap/1`, `try_wrap/1`

- **Reactive Coordination Patterns**
  - `Normandy.Coordination.Reactive` - Concurrent agent execution primitives
  - `race/3` - Return first successful result from multiple agents
  - `all/3` - Wait for all agents with optional fail-fast mode
  - `some/4` - Quorum pattern (wait for N successful results)
  - `map/3` - Transform agent results
  - `when_result/3` - Conditional execution based on results

- **Agent Pool Management**
  - `Normandy.Coordination.AgentPool` - Connection pool pattern for agents
  - Transaction-based API with automatic checkout/checkin
  - Manual checkout/checkin for advanced use cases
  - Configurable pool size with overflow support
  - LIFO/FIFO checkout strategies
  - Automatic agent replacement on failure
  - Pool statistics and monitoring
  - Non-blocking checkout with timeout support

#### Core Foundation (Phases 1-7)
- **Schema System**: Macro-based DSL for defining agent I/O schemas with JSON Schema generation
  - `Normandy.Schema` module with `schema` and `io_schema` macros
  - Type system with casting, dumping, and loading via `Normandy.Type`
  - Changeset-like validation with `Normandy.Validate`
  - Support for parameterized and custom types

- **Agent System**: Core agent implementation with LLM integration
  - `Normandy.Agents.BaseAgent` with init, run, and get_response methods
  - `Normandy.Agents.BaseAgentConfig` for agent state management
  - Context provider system for dynamic prompt injection
  - Tool/function calling support via `Normandy.Agents.ToolCallResponse`

- **Memory Management**: Conversational history tracking
  - `Normandy.Components.AgentMemory` with turn-based organization
  - Message serialization and deserialization
  - Configurable message history limits

- **Prompt System**: Structured prompt generation
  - `Normandy.Components.SystemPromptGenerator` with section-based prompts
  - `Normandy.Components.PromptSpecification` for prompt structure
  - `Normandy.Components.ContextProvider` protocol for dynamic context

- **Streaming Responses**: Real-time LLM response streaming
  - Streaming support in `Normandy.Agents.BaseAgent`
  - Callback-based streaming with arity-2 callback support

- **Resilience Patterns**: Fault tolerance and reliability
  - `Normandy.Resilience.Retry` with exponential backoff
  - `Normandy.Resilience.CircuitBreaker` for preventing cascade failures
  - Integration with BaseAgent for automatic retry on failures

- **Context Window Management**: Intelligent conversation management
  - `Normandy.Context.WindowManager` for automatic context management
  - `Normandy.Context.TokenCounter` for accurate token counting
  - `Normandy.Context.Summarizer` for conversation summarization
  - Support for Claude's prompt caching (up to 90% cost reduction)

#### Multi-Agent Coordination (Phase 8)
- **Agent Communication**: Message-based agent-to-agent communication
  - `Normandy.Coordination.AgentMessage` for structured messaging
  - `Normandy.Coordination.SharedContext` for stateless context sharing
  - `Normandy.Coordination.StatefulContext` (GenServer + ETS) for stateful sharing

- **Orchestration Patterns**: Multiple coordination strategies
  - `Normandy.Coordination.SequentialOrchestrator` for pipeline execution
  - `Normandy.Coordination.ParallelOrchestrator` for concurrent execution
  - `Normandy.Coordination.HierarchicalCoordinator` for manager-worker patterns
  - Simple and advanced APIs for flexible usage

- **Agent Processes**: OTP-based agent supervision
  - `Normandy.Coordination.AgentProcess` (GenServer wrapper)
  - `Normandy.Coordination.AgentSupervisor` (DynamicSupervisor)
  - Fault tolerance with Elixir/OTP patterns

#### Batch Processing
- **Concurrent Processing**: Efficient batch agent execution
  - `Normandy.Batch.Processor` for concurrent batch processing
  - Configurable concurrency limits
  - Result aggregation and error handling

#### Integration & Testing (Phase 8.5)
- **Integration Tests**: Comprehensive real-world testing
  - 56 integration tests with real Anthropic API calls
  - Test helpers: `IntegrationHelper` and `NormandyIntegrationHelper`
  - Tag-based test exclusion (`@moduletag :api`, `@moduletag :integration`)
  - Coverage for multi-agent workflows, resilience, caching, and batch processing

- **LLM Client Integration**: Claudio HTTP client migration
  - Updated to Claudio v0.1.1 from hex.pm
  - Migrated from Tesla to Req HTTP client
  - Streaming error handling for `Req.Response.Async`

### Fixed
- Orchestrator APIs: Fixed `extract_result` to return full response maps instead of just chat_message strings
- Function clause matching: Improved pattern matching for simple vs advanced orchestrator APIs
- Streaming callbacks: Fixed arity-2 callback support for streaming responses

### Documentation
- Comprehensive README with usage examples
- Project roadmap (ROADMAP.md) tracking implementation phases
- MIT License
- Hex.pm package metadata and documentation configuration

### Dependencies
- `elixir_uuid` ~> 1.2 - UUID generation for conversation turns
- `poison` ~> 6.0 - JSON encoding/decoding
- `claudio` ~> 0.1.1 - Anthropic Claude API client
- `dialyxir` ~> 1.4 (dev/test) - Static analysis
- `stream_data` ~> 1.1 (dev/test) - Property-based testing
- `ex_doc` ~> 0.34 (dev) - Documentation generation

### Test Coverage
- 443 unit tests (29 doctests + 21 properties + 393 tests)
- 62 integration tests (56 API + 6 comprehensive DSL tests, excluded by default)
- Total: 505 tests, all passing
- New test files:
  - `test/coordination/pattern_test.exs` (13 tests)
  - `test/coordination/reactive_test.exs` (33 tests)
  - `test/coordination/agent_pool_test.exs` (30 tests)
  - `test/dsl/agent_test.exs` (8 tests)
  - `test/dsl/workflow_test.exs` (14 tests)
  - `test/dsl/workflow_transform_integration_test.exs` (4 tests)
  - `test/normandy_integration/dsl_comprehensive_test.exs` (6 comprehensive integration tests)

[0.4.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.4.0
[0.3.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.3.0
[0.2.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.2.0
[0.1.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.1.0
