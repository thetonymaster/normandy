defmodule Normandy.DSL.AgentNoWarningsTest do
  use ExUnit.Case, async: true

  # A user compiling with --warnings-as-errors must not break on the code
  # `agent do` injects, whatever options the agent declares.
  @shapes [
    {"minimal", ~s|model("claude-haiku-4-5-20251001")|},
    {"system_prompt", ~s|model("claude-haiku-4-5-20251001")\nsystem_prompt("You help.")|},
    {"empty list", ~s|model("claude-haiku-4-5-20251001")\nbackground([])|},
    {"structured",
     ~s|model("claude-haiku-4-5-20251001")\nbackground(["a", "b"])\nsteps("1. Think")\noutput_instructions("JSON")|}
  ]

  for {{label, body}, idx} <- Enum.with_index(@shapes) do
    test "agent with #{label} options compiles without warnings" do
      mod = "Normandy.DSL.AgentNoWarningsTest.Gen#{unquote(idx)}"

      source = """
      defmodule #{mod} do
        use Normandy.DSL.Agent

        agent do
          #{unquote(body)}
        end
      end
      """

      # Per-process diagnostics: unlike capturing :stderr, other async tests
      # that compile code with a deliberate warning cannot leak into this one.
      {_, diagnostics} =
        Code.with_diagnostics([log: false], fn -> Code.compile_string(source) end)

      assert Enum.filter(diagnostics, &(&1.severity == :warning)) == []
    end
  end
end
