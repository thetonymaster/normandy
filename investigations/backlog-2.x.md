# Post-2.0 backlog

Items Q asked to keep for after the 2.0 release. One line each; link the evidence.

- [x] **Add Benchee** (Q, 2026-10-23; done in [#50](https://github.com/thetonymaster/normandy/pull/50): `mix bench`, see `bench/README.md`; inline experiment not run yet). The repo has no benchmarks (`bench/` absent, no `benchee` dep), so measure-first findings cannot be settled with numbers. Add `{:benchee, only: :dev}`, a `bench/` folder and a `mix bench` alias; first targets: `Normandy.Type` cast helpers (the unmeasured `@compile {:inline, ...}` at `lib/normandy/type.ex:841`, principles audit schema#10), `JsonDeserializer` region extraction (llm#1 fix), `AgentMemory.request_messages_for/2` on long histories, incremental output guards (`scratchpad guard_bench.exs` idea from the agents audit).
