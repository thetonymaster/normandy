defmodule Normandy.JSONStructEncodingTest do
  @moduledoc """
  Review Focus 4: a struct Jason has no encoder for, inside a tool result, a memory
  dump or a context-window estimate, is encoded as its map without __meta__ —
  never a Protocol.UndefinedError and never inspect/1 output sent to the model.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Components.{AgentMemory, BaseIOSchema, Message, ToolCall, ToolResult}
  alias Normandy.Context.{Summarizer, WindowManager}
  alias Normandy.Test.FakeTool

  defmodule Reading do
    @moduledoc false
    defstruct [:station, :celsius]
  end

  # Sends the summary request's messages to `notify`.
  defmodule RecordingClient do
    @moduledoc false
    defstruct [:notify]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:summarize_request, request.messages})

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: "summary"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  # A function, not a module attribute: the struct is not defined until the
  # module body around it compiles.
  defp reading, do: %Reading{station: "SFO", celsius: 15.5}
  @reading_json %{"station" => "SFO", "celsius" => 15.5}

  defp execute(output) do
    pipeline = %{Dispatch.default_pipeline() | execute_fn: fn _, _, _, _ -> output end}
    call = %ToolCall{id: "t1", name: "weather", input: %{}}
    invocation = %Dispatch.Invocation{tool: %FakeTool{}, input: %{}, timeout: 30_000}
    Dispatch.execute(%{name: "agent"}, invocation, call, pipeline)
  end

  defp model_content(%ToolResult{} = result) do
    [%{content: content}] = BaseIOSchema.to_json(result)
    content
  end

  test "a tool result is sent to the model as JSON with the struct as its map" do
    result = execute({:ok, %{readings: [reading()]}})

    assert %ToolResult{is_error: false} = result
    assert Jason.decode!(model_content(result)) == %{"readings" => [@reading_json]}
  end

  test "a tool output JSON cannot express becomes an error result naming its type" do
    assert %ToolResult{
             is_error: true,
             output: %{
               error: "the tool ran, but its output cannot be sent as JSON: it contains a tuple"
             }
           } = execute({:ok, %{at: {2026, 10, 5}}})
  end

  test "an error reason JSON cannot express is sent as its text" do
    result = execute({:error, {:http, 503}})

    assert %ToolResult{is_error: true, output: %{error: "{:http, 503}"}} = result
    assert Jason.decode!(model_content(result)) == %{"error" => "{:http, 503}"}
  end

  test "a memory dump encodes the struct as its map and loads it back as one" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: "t1", output: reading()})

    assert [%ToolResult{output: @reading_json}] =
             memory
             |> AgentMemory.dump()
             |> AgentMemory.load()
             |> AgentMemory.messages()
             |> Enum.map(fn %Message{content: content} -> content end)
  end

  test "a context-window estimate counts the struct's JSON" do
    expected = WindowManager.estimate_tokens(Jason.encode!(@reading_json))

    assert WindowManager.estimate_message_content_tokens(reading()) == expected
    assert WindowManager.estimate_message_content_tokens([reading()]) == expected
  end

  test "the summary prompt shows the struct as JSON, not inspect output" do
    agent = BaseAgent.init(%{client: %RecordingClient{}, model: "m"})
    messages = [%{role: "user", content: reading()}]

    {:ok, "summary"} =
      Summarizer.summarize_messages(%RecordingClient{notify: self()}, agent, messages)

    assert_received {:summarize_request, [%Message{content: prompt}]}
    assert prompt =~ ~s("station":"SFO")
    refute prompt =~ "%Normandy.JSONStructEncodingTest.Reading{"
  end
end
