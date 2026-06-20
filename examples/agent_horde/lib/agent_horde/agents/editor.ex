defmodule AgentHorde.Agents.Editor do
  @moduledoc """
  Editor that synthesizes analyst findings into a single well-structured report.
  Returns Markdown prose — no structured JSON output.
  """

  use Normandy.DSL.Agent

  agent do
    model("claude-sonnet-4-6")
    temperature(0.4)
    max_tokens(4096)

    background("You are an editor synthesizing analyst findings into one report.")

    output_instructions("""
    Produce a well-structured Markdown report: a title, a 2-3 sentence summary,
    key findings as bullets, and a Sources section listing the URLs. Output raw Markdown
    only — do NOT output JSON, and do NOT wrap the entire response in a code fence.
    """)
  end
end
