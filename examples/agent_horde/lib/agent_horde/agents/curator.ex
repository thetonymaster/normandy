defmodule AgentHorde.Agents.Curator do
  @moduledoc """
  Selects the most relevant sources to read in full from a set of search results.
  Returns prose — no structured JSON output.
  """

  use Normandy.DSL.Agent

  agent do
    model("claude-sonnet-4-6")
    temperature(0.3)

    background("You select the most relevant sources to read in full.")

    output_instructions("""
    Given numbered search results, output ONLY the URLs worth scraping, one per line —
    at most 4, highest-signal first. No commentary, no JSON, no code fences.
    """)
  end
end
