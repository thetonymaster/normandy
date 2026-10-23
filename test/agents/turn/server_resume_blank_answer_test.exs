defmodule Normandy.Agents.Turn.ServerResumeBlankAnswerTest do
  @moduledoc """
  An eagerly resumed `Turn.Server` turn validates its final answer with the stored config,
  which never went through `BaseAgent.with_default_output_schema/1`: a template with
  `output_schema: nil` is still a chat agent. Its blank final answer is the
  `:invalid_output` failure, the tool-round fallback still applies, and the resumed run's
  `:stop` (`resumed: true`) carries `answer_source`.
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
  alias Normandy.LLMError
  alias Normandy.Test.FakeClient
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.TelemetryCapture

  @events [[:normandy, :agent, :run, :stop], [:normandy, :agent, :run, :exception]]

  # A :steering turn stored after its tool round (the model's tool-calling reply carried
  # `round_text`), resumed eagerly by a server whose config has output_schema: nil; the
  # resumed final call answers blank.
  defp resume(round_text) do
    name = "resume-blank-#{System.unique_integer([:positive])}"
    sid = "s-#{name}"
    TelemetryCapture.attach_span(@events, agent_name: name, resumed: true)
    store = InMemory.new()

    for {role, content} <- [
          {"user", "Capital of France?"},
          {"assistant",
           %ToolCallResponse{
             content: round_text,
             tool_calls: [%ToolCall{id: "t1", name: "record_city", input: %{}}]
           }},
          {"tool", %ToolResult{tool_call_id: "t1", output: "recorded"}}
        ] do
      {:ok, _} =
        InMemory.append_entry(store, sid, %AgentMemory.Entry{
          turn_id: "live",
          role: role,
          content: content
        })
    end

    turn_state = %Turn.State{
      status: :steering,
      iterations_left: 4,
      max_iterations: 5,
      response_model: %ToolCallResponse{},
      output_schema: %BaseAgentOutputSchema{}
    }

    :ok = InMemory.save_turn_state(store, sid, turn_state, true)

    config =
      %{client: FakeClient.new([{:text, ""}]), model: "m", max_tokens: 64, name: name}
      |> BaseAgent.init()
      |> BaseAgent.register_tool(%ReturnTool{name: "record_city", output: "recorded"})

    {:ok, _srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: %{config | output_schema: nil},
        store: {InMemory, store},
        registry: {Native, Native.new()},
        resume_policy: :eager
      )

    {store, sid}
  end

  test "a blank final answer is :invalid_output" do
    {store, sid} = resume(nil)

    assert_receive {:span, [:normandy, :agent, :run, :exception], meta}, 2_000
    refute Map.has_key?(meta, :answer_source)

    assert {:ok, %Turn.State{status: :failed, error: %LLMError{type: :invalid_output}}} =
             InMemory.load_turn_state(store, sid)
  end

  test "the tool round's text answers, marked answer_source: :tool_round" do
    {store, sid} = resume("Paris.")

    assert_receive {:span, [:normandy, :agent, :run, :stop], meta}, 2_000
    assert meta.answer_source == :tool_round

    assert {:ok, %Turn.State{status: :stopped, final_response: %{chat_message: "Paris."}}} =
             InMemory.load_turn_state(store, sid)
  end
end
