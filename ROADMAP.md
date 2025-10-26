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

## Upcoming Phases 🚀

### Phase 8.5: Integration Testing
**Priority**: HIGH - Before moving to Phase 9

**Scope**:
- End-to-end multi-agent workflow tests
- Integration tests for coordination patterns
- Performance benchmarks for concurrent operations
- Load testing for agent supervisor
- Integration with existing resilience features
- Real-world multi-agent scenarios

**Deliverables**:
- `test/integration/` directory structure
- Multi-agent workflow integration tests
- Performance benchmarking suite
- Load/stress testing scenarios
- Documentation of integration patterns

---

### Phase 9: Observability & Logging
**Status**: Not Started

**Goals**:
- Structured logging for agent operations
- Telemetry integration for metrics
- Tracing for agent execution flows
- Debug/replay capabilities for conversations

**Key Features**:
- `Normandy.Observability.Logger` - Structured logging
- `Normandy.Observability.Telemetry` - Metrics and events
- `Normandy.Observability.Tracer` - Execution flow tracing
- `Normandy.Observability.Replay` - Conversation replay/debug

**Integration Points**:
- `:telemetry` library for events
- `:logger` metadata for correlation IDs
- Distributed tracing support (OpenTelemetry)
- Agent execution timeline visualization

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
| 8.5 | ⏳ Pending | TBD | TBD | - |
| 9 | 📋 Planned | - | - | - |
| 10 | 📋 Planned | - | - | - |
| 11 | 📋 Planned | - | - | - |
| 12 | 📋 Planned | - | - | - |

---

## Notes

- All phases should leverage Elixir/OTP primitives where applicable
- Maintain backwards compatibility within major versions
- Prioritize production-readiness and fault tolerance
- Document performance characteristics and tradeoffs
