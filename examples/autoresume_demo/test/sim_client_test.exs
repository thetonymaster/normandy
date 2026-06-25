defmodule AutoresumeDemo.SimClientTest do
  use ExUnit.Case, async: true

  alias AutoresumeDemo.SimClient
  alias Normandy.Agents.Model
  alias Normandy.Agents.ToolCallResponse

  defp msg(role), do: %{role: role, content: "x"}

  test "emits a research_step tool call early in the conversation" do
    c = %SimClient{topic: "raft", total_steps: 3, step_delay_ms: 0}
    {resp, nil} = Model.converse(c, "m", 0.7, 1024, [msg("user")], %ToolCallResponse{}, [])
    assert [%{name: "research_step", input: %{"n" => 1}}] = resp.tool_calls
  end

  test "finalizes (no tool calls) once total_steps assistant turns have happened" do
    c = %SimClient{topic: "raft", total_steps: 2, step_delay_ms: 0}
    msgs = [msg("user"), msg("assistant"), msg("tool"), msg("assistant"), msg("tool")]
    {resp, nil} = Model.converse(c, "m", 0.7, 1024, msgs, %ToolCallResponse{}, [])
    assert resp.tool_calls == []
    assert resp.content =~ "raft"
  end
end
