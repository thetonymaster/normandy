# verify/durable_server_live.exs — one real Haiku turn through AgentProcess :server mode.
# Owned in-memory infra (no Postgres needed; Task 4 covers PG durability stubbed).
Code.require_file("support.exs", __DIR__)
Smoke.Support.start()

alias Normandy.Coordination.AgentProcess

agent =
  %Normandy.Agents.BaseAgentConfig{
    client: Smoke.Support.client(),
    model: Smoke.Support.model(),
    temperature: 0.0,
    max_tokens: 32,
    memory: Normandy.Components.AgentMemory.new_memory(),
    initial_memory: Normandy.Components.AgentMemory.new_memory(),
    prompt_specification: %Normandy.Components.PromptSpecification{},
    input_schema: %Normandy.Agents.BaseAgentInputSchema{},
    output_schema: %Normandy.Agents.BaseAgentOutputSchema{}
  }

{:ok, pid} = AgentProcess.start_link(agent: agent, turn_engine: :server)

Smoke.Support.record_call!()
{:ok, _response} = AgentProcess.run(pid, "Reply with the single word: ready")

# DURABILITY INVARIANT: get_agent reconstructs memory from the store, including the turn.
reconstructed = AgentProcess.get_agent(pid)
msgs = Normandy.Components.AgentMemory.messages(reconstructed.memory)

Smoke.Support.assert!(
  "durable :server reconstructs conversation memory after a live turn",
  length(msgs) >= 2,
  "expected user+assistant in reconstructed memory, got #{length(msgs)} messages"
)

Smoke.Support.report()
