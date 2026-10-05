# Used by "mix format"
locals_without_parens = [
  # Normandy.DSL.Agent
  agent: 1,
  name: 1,
  description: 1,
  model: 1,
  temperature: 1,
  max_tokens: 1,
  max_tool_concurrency: 1,
  system_prompt: 1,
  background: 1,
  steps: 1,
  output_instructions: 1,
  tool: 1,
  memory: 0,
  memory: 1,
  max_messages: 1,
  guardrails: 2,
  guardrails: 3,
  streaming_mode: 1,
  streaming_chunk_size: 1,
  hooks: 1,
  # Normandy.DSL.Workflow
  workflow: 1,
  step: 2,
  parallel: 2,
  race: 2,
  agent: 2,
  input: 1,
  transform: 1,
  when_result: 1,
  # Normandy.Schema
  schema: 1,
  io_schema: 2,
  field: 1,
  field: 2,
  field: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  export: [locals_without_parens: locals_without_parens]
]
