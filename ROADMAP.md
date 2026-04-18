# Normandy Development Roadmap

This document tracks the phased implementation of the Normandy AI agent framework.

## Completed Phases ✅

### Phase 1-7: Core Foundation
- ✅ Basic agent architecture
- ✅ LLM client integrations
- ✅ Tool/function calling
- ✅ Memory and conversation management
- ✅ Streaming responses
- ✅ Resilience (retry, circuit breaker)
- ✅ Context window management, token counting, summarization

### Phase 8: Multi-Agent Coordination ✅
**Status**: Completed - Commit 7f8d55b

**Implemented**:
- Agent-to-agent message passing (AgentMessage)
- Sequential orchestration (pipeline pattern)
- Parallel orchestration (concurrent execution)
- Hierarchical coordination (manager-worker)
- Shared context (stateless and GenServer-backed)
- Agent processes with supervision (AgentProcess, AgentSupervisor)
- Fault tolerance with OTP patterns
- 76 new tests, 380 total tests passing

**Key Modules**:
- `Normandy.Coordination.AgentMessage`
- `Normandy.Coordination.SharedContext`
- `Normandy.Coordination.StatefulContext` (GenServer + ETS)
- `Normandy.Coordination.SequentialOrchestrator`
- `Normandy.Coordination.ParallelOrchestrator`
- `Normandy.Coordination.HierarchicalCoordinator`
- `Normandy.Coordination.AgentProcess` (GenServer wrapper)
- `Normandy.Coordination.AgentSupervisor` (DynamicSupervisor)

### Phase 8.5: Integration Testing & Claudio Migration ✅
**Status**: Completed - 2025-10-26

**Implemented**:
- Migrated Claudio HTTP client from Tesla to Req
- Fixed orchestrator APIs for simplified usage
- Added streaming callback support (arity-2 callbacks)
- Trimmed integration tests for cost efficiency (56 tests)
- Real Anthropic API integration testing
- End-to-end workflow validation
- Multi-agent coordination tests
- Batch processing and performance tests
- Resilience and caching tests
- Comprehensive test helper utilities

**Test Files** (Trimmed to essential coverage):
- `test/integration/agent_tool_execution_flow_test.exs` (1 test)
- `test/integration/agent_resilience_integration_test.exs` (11 tests)
- `test/integration/agent_context_management_test.exs` (12 tests)
- `test/integration/batch_coordination_integration_test.exs` (12 tests)
- `test/integration/multi_agent_workflows_test.exs` (2 tests)
- `test/integration/llm_caching_integration_test.exs` (11 tests)
- `test/integration/end_to_end_scenarios_test.exs` (2 tests)
- `test/normandy_integration/basic_agent_test.exs` (2 tests)
- `test/normandy_integration/multi_agent_test.exs` (2 tests)

**Key Features**:
- `NormandyTest.Support.IntegrationHelper` - API setup and utilities
- `NormandyTest.Support.NormandyIntegrationHelper` - Normandy-specific helpers
- API key management (supports both `API_KEY` and `ANTHROPIC_API_KEY`)
- Tag-based test exclusion (`@moduletag :api`, `@moduletag :integration`)
- Real-world scenario testing with reduced API costs

**Orchestrator Improvements**:
- `ParallelOrchestrator.execute/2` - Simple API: `execute(agents, input)` returns `{:ok, [results]}`
- `SequentialOrchestrator.execute/2` - Simple API: `execute(agents, input)` returns `{:ok, final_result}`
- Advanced API still available with full `execution_result` maps
- Fixed `extract_result` to return full response maps instead of just chat_message strings

### Phase 8.6: Developer Experience Enhancements ✅
**Status**: Completed - 2025-10-26

**Implemented**:
- Reactive patterns for concurrent agent execution
- Agent pooling with fault tolerance and overflow handling
- Comprehensive documentation and examples
- 63 new tests (33 for Reactive, 30 for AgentPool)
- Updated README with multi-agent coordination section

**Key Modules**:
- `Normandy.Coordination.Reactive` - Race, all, some patterns for concurrent execution
- `Normandy.Coordination.AgentPool` - Pool manager with checkout/checkin, overflow, and monitoring

**Reactive Patterns**:
- `race/3` - Return first successful result from multiple agents
- `all/3` - Wait for all agents to complete with optional fail-fast
- `some/4` - Wait for N successful results (quorum pattern)
- `map/3` - Transform agent results
- `when_result/3` - Conditional execution based on results

**Agent Pool Features**:
- Transaction-based API with automatic checkout/checkin
- Manual checkout/checkin for advanced use cases
- Configurable pool size with overflow support
- LIFO/FIFO checkout strategies
- Automatic agent replacement on failure
- Pool statistics and monitoring
- Non-blocking checkout with timeout support

**Test Coverage**:
- 33 comprehensive tests for Reactive patterns
- 30 comprehensive tests for AgentPool
- Total unit tests: 443 (up from 380)
- All tests passing with full coverage

**Documentation**:
- Added "Multi-Agent Coordination" section to README
- Reactive patterns examples with all options
- Agent pooling examples with configuration
- Agent process lifecycle examples
- Use cases for each pattern
- Updated features list and architecture section

### Phase 9: Observability & Logging ✅
**Status**: Completed - 2026-04-18

**Implemented**:
- Structured logging for agent, LLM, and tool lifecycle events
- Telemetry integration for metrics and events
- OpenTelemetry-friendly logging with span context correlation
- Duration tracking for all key operations
- Metadata enrichment with agent names, models, and tool names
- Error tracking and exception logging for all spans

**Key Modules**:
- `Normandy.Agents.BaseAgent` - Integrated telemetry and logging
- `Normandy.Agents.ValidationMiddleware` - Integrated logging for validation
- `Normandy.Tools.Executor` - Telemetry for tool execution

### Phase 13: Protocol Interoperability (MCP & A2A) ✅
**Status**: Completed - 2026-04-18

**Implemented**:
- Model Context Protocol (MCP) support for tool sharing
- Agent-to-Agent (A2A) protocol for cross-agent collaboration
- Tool registry wrappers for MCP servers
- Standardized server implementation for agent exposure

**Key Modules**:
- `Normandy.MCP.ToolWrapper`
- `Normandy.MCP.Registry`
- `Normandy.A2A.Server`
- `Normandy.A2A.AgentTool`

## Upcoming Phases 🚀

---

### Phase 10: Performance Optimization
**Status**: Not Started

**Goals**:
- Response caching layer
- Concurrent tool execution
- Memory optimization for long conversations
- Lazy loading strategies

**Key Features**:
- `Normandy.Cache` - Response caching with TTL
- `Normandy.Tools.ConcurrentExecutor` - Parallel tool calls
- `Normandy.Memory.Optimizer` - Conversation pruning
- `Normandy.Loader` - Lazy loading for large contexts

**Optimizations**:
- ETS-based caching for responses
- Parallel tool execution when independent
- Automatic conversation summarization triggers
- On-demand loading of historical context

---

### Phase 11: Production Features
**Status**: Not Started

**Goals**:
- Rate limiting per agent/client
- Cost tracking and budget controls
- A/B testing framework for prompts
- Audit logging for compliance

**Key Features**:
- `Normandy.RateLimit` - Per-agent/client throttling
- `Normandy.CostTracking` - Token/cost monitoring
- `Normandy.Experimentation` - A/B testing for prompts
- `Normandy.Audit` - Compliance logging

**Production Readiness**:
- Configurable rate limits (per second/minute/hour)
- Budget alerts and hard stops
- Prompt variant testing framework
- Immutable audit trail for sensitive operations

---

### Phase 12: Developer Experience
**Status**: Not Started

**Goals**:
- Mix tasks for common operations
- Development console/REPL enhancements
- Code generation for schemas
- Testing utilities and factories

**Key Features**:
- `mix normandy.gen.agent` - Agent scaffolding
- `mix normandy.gen.tool` - Tool function generator
- `mix normandy.console` - Interactive REPL
- `Normandy.Factory` - Test data factories

**DX Improvements**:
- CLI for agent creation and testing
- Interactive prompt development
- Schema code generation from examples
- Comprehensive test helpers

---

## Development Guidelines

### Testing Requirements
- Minimum 80% code coverage
- Integration tests for all coordination patterns
- Property-based tests for complex logic
- Performance benchmarks for critical paths

### Documentation Standards
- Moduledoc for all public modules
- @doc for all public functions
- Examples in docstrings
- Integration guides for new features

### Commit Message Format
```
<type>: <subject>

<body>

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

---

## Progress Tracking

| Phase | Status | Tests | Modules | Completion Date |
|-------|--------|-------|---------|-----------------|
| 1-7 | ✅ Complete | 304 | ~30 | 2025-10-26 |
| 8 | ✅ Complete | 380 | 38 | 2025-10-26 |
| 8.5 | ✅ Complete | 480 (380+100 integration) | 39 | 2025-10-26 |
| 8.6 | ✅ Complete | 493 (443+56 integration) | 40 | 2025-10-26 |
| 9 | ✅ Complete | 505+ | ~45 | 2026-04-18 |
| 13 | ✅ Complete | 505+ | ~50 | 2026-04-18 |
| 10 | 📋 Planned | - | - | - |
| 11 | 📋 Planned | - | - | - |
| 12 | 📋 Planned | - | - | - |

---

## Notes

- All phases should leverage Elixir/OTP primitives where applicable
- Maintain backwards compatibility within major versions
- Prioritize production-readiness and fault tolerance
- Document performance characteristics and tradeoffs
