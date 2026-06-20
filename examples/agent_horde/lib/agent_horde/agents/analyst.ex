defmodule AgentHorde.Agents.Analyst do
  @moduledoc """
  Rigorous research analyst that synthesizes scraped source content into a
  concise factual analysis. Returns prose — no structured JSON output.

  The baked model is `claude-sonnet-4-6` but is overridden per provider at
  `new/1` time by passing `model: "..."` as a top-level option:

      {:ok, agent} = AgentHorde.Agents.Analyst.new(client: client, model: "gpt-4o")
  """

  use Normandy.DSL.Agent

  agent do
    model("claude-sonnet-4-6")
    temperature(0.4)

    background("You are a rigorous research analyst.")

    output_instructions("""
    Write a concise, factual analysis (4-8 sentences) grounded ONLY in the provided sources.
    Plain prose. No JSON, no code fences.
    """)
  end
end
