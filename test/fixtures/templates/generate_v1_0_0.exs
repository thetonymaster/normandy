# Generates v1_0_0_session_template.etf with Normandy v1.0.0's own BaseAgent.init/1 and
# ConfigTemplate.from_config/3, the way a 1.0 Postgres or Redis store persisted it
# (:erlang.term_to_binary/1). Not part of the suite. Run it in an export of the v1.0.0 tag,
# never in this tree:
#
#     mkdir -p /tmp/normandy-1.0.0 && git archive v1.0.0 | tar -x -C /tmp/normandy-1.0.0
#     cd /tmp/normandy-1.0.0 && mix deps.get && mix compile
#     mix run --no-start /path/to/this/file.exs /path/to/v1_0_0_session_template.etf
alias Normandy.Agents.{BaseAgent, ConfigTemplate}
alias Normandy.Behaviours.{Compactor, Config}
alias Normandy.Components.{AgentMemory, PromptSpecification}

config =
  BaseAgent.init(%{
    client: %URI{host: "fixture.invalid"},
    model: "claude-sonnet-4-6",
    temperature: 0.9,
    name: "support",
    memory: AgentMemory.new_memory(50),
    prompt_specification: %PromptSpecification{background: ["You answer billing questions."]},
    behaviours: %Config{
      compactor: {Compactor.WindowManager, [max_tokens: 200_000, strategy: :oldest_first]}
    }
  })

template = ConfigTemplate.from_config(config, "tmpl-v1", :eager)
[out] = System.argv()
File.write!(out, :erlang.term_to_binary(template))
IO.puts("v1.0.0 template: " <> inspect(template, limit: :infinity, pretty: true))
