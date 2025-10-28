# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Enhanced ExDoc configuration with organized module groups
- Guides directory structure for comprehensive documentation

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

[0.1.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.1.0
