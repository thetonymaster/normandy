defmodule AgentHorde.Agents.Planner do
  @moduledoc """
  Plans web research by generating focused search queries for a given question.
  Returns prose — no structured JSON output.
  """

  use Normandy.DSL.Agent

  agent do
    model("claude-sonnet-4-6")
    temperature(0.5)

    background("You plan web research. Given a question, produce focused search queries.")

    output_instructions("""
    Output ONLY 3 search queries, one per line, no numbering, no commentary,
    no JSON, no code fences. Each query is a concise web search string.
    """)
  end
end
