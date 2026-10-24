# Normandy examples

The example applications that used to live here (`agent_horde` and the customer support
app) were written for Normandy 1.x and do not compile against 2.0, so they were removed.
The guides show 2.0 end to end:

- [Distributed sessions](../docs/guides/distributed_sessions.md): durable `Turn.Session`s,
  session stores and registries, running on a cluster.
- [Agent memory](../docs/guides/agent-memory.md): the `memory` tool, namespaces and memory
  stores.
- [Hooks](../docs/guides/hooks.md): lifecycle hooks around prompts, LLM calls, tools and
  compaction.
- [Testing](../docs/guides/testing.md): `Normandy.Test.FakeClient` and the store contracts.

The [README](../README.md) has the quickstart, and [MIGRATING-2.0.md](../MIGRATING-2.0.md)
the changes from 1.x.

## A tool that calls an HTTP API

[`tools/weather.ex`](tools/weather.ex) defines `MyApp.Tools.Weather`, a `Normandy.Tool` that
fetches the current weather from Open-Meteo (no API key needed). Copy it into your
application and rename the module. It is not part of the Normandy package.
