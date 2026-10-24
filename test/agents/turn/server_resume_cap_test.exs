defmodule Normandy.Agents.Turn.ServerResumeCapTest do
  @moduledoc """
  A server that stopped after it appended a tool round's results, but before it saved the
  `:steering` state that counts the round, restarts from the state saved one round
  earlier. The resumed turn must count the round the history holds: past
  `max_tool_iterations` its next call is the final one (`tool_choice: :none`), after the
  iteration-cap notice.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.FakeClient
  alias Normandy.Test.ReturnTool

  @cap_notice "You have used all available tool calls for this turn."

  defp tool_round(id) do
    [
      {"assistant",
       %ToolCallResponse{tool_calls: [%ToolCall{id: id, name: "record_city", input: %{}}]}},
      {"tool", %ToolResult{tool_call_id: id, output: "recorded"}}
    ]
  end

  # `rounds` completed tool rounds in the stored history of turn "live", and a :steering
  # state saved with `iterations_left` of `max`.
  defp resume(rounds, iterations_left, max) do
    sid = "s-cap-#{System.unique_integer([:positive])}"
    store = InMemory.new()
    stored = [{"user", "Capital of France?"} | Enum.flat_map(1..rounds//1, &tool_round("t#{&1}"))]

    for {role, content} <- stored do
      {:ok, _} =
        InMemory.append_entry(store, sid, %AgentMemory.Entry{
          turn_id: "live",
          role: role,
          content: content
        })
    end

    turn_state = %Turn.State{
      status: :steering,
      iterations_left: iterations_left,
      max_iterations: max,
      response_model: %ToolCallResponse{},
      output_schema: %BaseAgentOutputSchema{}
    }

    :ok = InMemory.save_turn_state(store, sid, turn_state, true)
    client = FakeClient.new([{:text, "Paris."}])

    config =
      %{client: client, model: "m", max_tokens: 64, max_tool_iterations: max}
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%ReturnTool{name: "record_city", output: "recorded"})

    {:ok, _srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        resume_policy: :eager
      )

    wait_until_stopped(store, sid)
    {client, store, sid}
  end

  defp wait_until_stopped(store, sid, tries \\ 100) do
    case InMemory.load_turn_state(store, sid) do
      {:ok, %Turn.State{status: status}} when status in [:stopped, :failed] ->
        :ok

      _other when tries > 0 ->
        Process.sleep(20)
        wait_until_stopped(store, sid, tries - 1)
    end
  end

  # Every text the request sends; the notice after tool results is a text block of the
  # results' message (AgentMemory.request_messages/1).
  defp texts(request) do
    for %{content: content} <- request.messages, block <- List.wrap(content) do
      case block do
        text when is_binary(text) -> text
        %{type: "text", text: text} -> text
        _other -> ""
      end
    end
  end

  test "the round the stale state does not count makes the next call the final one" do
    {client, store, sid} = resume(2, 1, 2)

    assert [request] = FakeClient.requests(client)
    assert request.tool_choice == :none
    assert Enum.any?(texts(request), &String.starts_with?(&1, @cap_notice))

    assert {:ok, %Turn.State{status: :stopped, stop_reason: :max_iterations}} =
             InMemory.load_turn_state(store, sid)
  end

  test "a state that counts every stored round resumes as it was saved" do
    {client, _store, _sid} = resume(1, 1, 2)

    assert [request] = FakeClient.requests(client)
    assert request.tool_choice == nil
    refute Enum.any?(texts(request), &String.starts_with?(&1, @cap_notice))
  end
end
