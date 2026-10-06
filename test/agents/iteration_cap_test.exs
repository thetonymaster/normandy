defmodule Normandy.Agents.IterationCapTest do
  @moduledoc """
  AX-5: at max_tool_iterations the final call keeps the loop's response model, system
  prompt and tools, sets tool_choice :none, and follows a persisted notice; the core
  converts its answer like any other final answer.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  alias Normandy.LLMError
  alias Normandy.Test.FakeTool

  @notice "You have used all available tool calls for this turn. Answer now with what you " <>
            "have, and say what you could not finish."

  defmodule Decision do
    use Normandy.Schema

    io_schema "A decision" do
      field(:action, :string, required: true)
    end
  end

  # Calls the weather tool on every request until one carries tool_choice: :none,
  # then answers `final`, after pausing (pause_turn) on the first `final_pauses`
  # final calls. Each request goes to `notify`.
  defmodule CapClient do
    defstruct final: "", final_pauses: 0, notify: nil, options: %{}

    defimpl Normandy.Agents.Model do
      alias Normandy.Agents.ToolCallResponse
      alias Normandy.Components.ToolCall
      alias Normandy.LLM.Response

      def converse(client, request, _opts) do
        send(client.notify, {:request, request})

        content =
          case request.tool_choice do
            :none ->
              if pause?(client, request),
                do: %ToolCallResponse{content: "Still searching.", stop_reason: :pause_turn},
                else: %ToolCallResponse{content: client.final}

            nil ->
              %ToolCallResponse{tool_calls: [call(request)]}
          end

        {:ok, %Response{content: content, stop_reason: content.stop_reason || :end_turn}}
      end

      def stream(client, request, _opts) do
        send(client.notify, {:request, request})

        start = %{
          type: "message_start",
          message: %{"id" => "msg", "model" => "m", "role" => "assistant"}
        }

        paused? = request.tool_choice == :none and pause?(client, request)

        stop = [
          %{
            type: "message_delta",
            delta: %{"stop_reason" => if(paused?, do: "pause_turn", else: "end_turn")},
            usage: %{}
          },
          %{type: "message_stop"}
        ]

        text = if paused?, do: "Still searching.", else: client.final

        blocks =
          case request.tool_choice do
            :none ->
              [
                %{
                  type: "content_block_start",
                  index: 0,
                  content_block: %{"type" => "text", "text" => ""}
                },
                %{
                  type: "content_block_delta",
                  index: 0,
                  delta: %{"type" => "text_delta", "text" => text}
                },
                %{type: "content_block_stop", index: 0}
              ]

            nil ->
              %ToolCall{id: id} = call(request)

              [
                %{
                  type: "content_block_start",
                  index: 0,
                  content_block: %{
                    "type" => "tool_use",
                    "id" => id,
                    "name" => "weather",
                    "input" => %{}
                  }
                },
                %{
                  type: "content_block_delta",
                  index: 0,
                  delta: %{"type" => "input_json_delta", "partial_json" => ~s({"city": "Paris"})}
                },
                %{type: "content_block_stop", index: 0}
              ]
          end

        {:ok, [start | blocks] ++ stop}
      end

      # A paused final call goes back with the paused turn last: the trailing
      # assistant messages count the pauses so far.
      defp pause?(client, request) do
        pauses =
          request.messages
          |> Enum.reverse()
          |> Enum.take_while(&(&1.role == "assistant"))
          |> length()

        pauses < client.final_pauses
      end

      # One id per round, so every tool_use in the conversation is distinct.
      defp call(request) do
        round = Enum.count(request.messages, &(&1.role == "assistant"))
        %ToolCall{id: "toolu_#{round}", name: "weather", input: %{"city" => "Paris"}}
      end
    end
  end

  defp agent(final, extra \\ %{}) do
    {pauses, extra} = Map.pop(extra, :final_pauses, 0)
    client = %CapClient{final: final, final_pauses: pauses, notify: self()}

    %{client: client, model: "m", max_tool_iterations: 2}
    |> Map.merge(extra)
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%FakeTool{})
  end

  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  # The notice travels as the last block of the last batch's tool-result message
  # (request_messages/1), not as a message of its own.
  defp assert_notice_in_tool_message(messages) do
    assert %Message{role: "tool", content: blocks} = List.last(messages)
    assert List.last(blocks) == %{type: "text", text: @notice}
    refute Enum.any?(messages, &(&1.role == "user" and &1.content == @notice))
  end

  describe "run/3 (sync)" do
    test "the final call keeps the loop's model, prompt and tools and sets tool_choice :none" do
      assert {:ok, config, %BaseAgentOutputSchema{chat_message: "Paris: weather in Paris"}} =
               BaseAgent.run(agent("Paris: weather in Paris"), "weather?")

      assert [first, second, final] = requests()
      assert first.tool_choice == nil
      assert second.tool_choice == nil
      assert final.tool_choice == :none
      assert %ToolCallResponse{} = final.response_model
      assert final.system == first.system
      assert final.tools == first.tools
      assert_notice_in_tool_message(final.messages)

      # The notice is persisted after the last batch's results, before the answer.
      roles_and_text =
        config.memory |> AgentMemory.messages() |> Enum.map(&{&1.role, &1.content})

      assert [
               {"user", _input},
               {"assistant", _},
               {"tool", _},
               {"assistant", _},
               {"tool", _},
               {"user", @notice},
               {"assistant", %BaseAgentOutputSchema{chat_message: "Paris: weather in Paris"}}
             ] = roles_and_text
    end

    test "a non-chat output schema's final text is converted by the core" do
      assert {:ok, _config, %Decision{action: "stop"}} =
               BaseAgent.run(agent(~s({"action": "stop"}), %{output_schema: %Decision{}}), "go")

      # Task 5.1: every tool-loop call, the final one included, carries the format.
      assert [_, _, %{tool_choice: :none, output_format: %Decision{}}] = requests()
    end
  end

  describe "stream/3" do
    test "the final streamed call sets tool_choice :none and is converted once" do
      assert {:ok, _config, %Decision{action: "stop"}} =
               BaseAgent.stream(
                 agent(~s({"action": "stop"}), %{output_schema: %Decision{}}),
                 "go",
                 fn _ -> :ok end
               )

      assert [%{tool_choice: nil} = first, %{tool_choice: nil}, %{tool_choice: :none} = final] =
               requests()

      assert final.system == first.system
      assert final.tools == first.tools
      assert_notice_in_tool_message(final.messages)
    end
  end

  describe "Turn.Server" do
    test "persists the notice and the final answer" do
      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-cap",
          config: agent("done"),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
               Server.run(srv, %{chat_message: "go"})

      assert {:ok, entries} = InMemory.history(store, "s-cap")

      assert ["user", "assistant", "tool", "assistant", "tool", "user", "assistant"] =
               Enum.map(entries, & &1.role)

      assert Enum.at(entries, 5).content == @notice
      assert List.last(requests()).tool_choice == :none
    end
  end

  # X1: a pause_turn on the final call is continued as the final call (tool_choice
  # :none, the paused turn sent back last, no user message), at most 3 times; a 4th
  # pause is a :pause_turn LLMError (decision 23).
  describe "a paused final call" do
    defp assert_continued_final(paused_call, continued) do
      assert paused_call.tool_choice == :none
      assert continued.tool_choice == :none
      assert continued.system == paused_call.system
      assert continued.tools == paused_call.tools
      assert %Message{role: "assistant"} = List.last(continued.messages)
      assert_notice_in_tool_message(Enum.drop(continued.messages, -1))
    end

    test "run/3 continues it as the final call and stores the notice once" do
      assert {:ok, config, %BaseAgentOutputSchema{chat_message: "done"}} =
               BaseAgent.run(agent("done", %{final_pauses: 1}), "weather?")

      assert [_, _, paused_call, continued] = requests()
      assert_continued_final(paused_call, continued)

      roles = config.memory |> AgentMemory.messages() |> Enum.map(& &1.role)

      assert roles == [
               "user",
               "assistant",
               "tool",
               "assistant",
               "tool",
               "user",
               "assistant",
               "assistant"
             ]

      assert config.memory |> AgentMemory.messages() |> Enum.count(&(&1.content == @notice)) == 1
    end

    # Two loop calls, then the final call and its 3 continuations, all tool_choice :none.
    defp assert_four_final_calls do
      assert [%{tool_choice: nil}, %{tool_choice: nil} | finals] = requests()
      assert length(finals) == 4
      assert Enum.all?(finals, &(&1.tool_choice == :none))
    end

    defp assert_pause_turn_error(error) do
      assert %LLMError{type: :pause_turn, retryable?: false, reason: {:stop_reason, :pause_turn}} =
               error

      refute error.message =~ "Still searching."
    end

    test "run/3 returns a :pause_turn error after 3 continuations" do
      assert {:error, error} = BaseAgent.run(agent("done", %{final_pauses: 100}), "weather?")
      assert_pause_turn_error(error)
      assert_four_final_calls()
    end

    test "stream/3 returns a :pause_turn error after 3 continuations" do
      assert {:error, error} =
               BaseAgent.stream(agent("done", %{final_pauses: 100}), "weather?", fn _ -> :ok end)

      assert_pause_turn_error(error)
      assert_four_final_calls()
    end

    test "Turn.Server replies with a :pause_turn error after 3 continuations" do
      {:ok, srv} =
        Server.start_link(
          session_id: "s-cap-pause-fail",
          config: agent("done", %{final_pauses: 100}),
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()}
        )

      assert {:error, error} = Server.run(srv, %{chat_message: "go"})
      assert_pause_turn_error(error)
      assert_four_final_calls()
    end

    test "stream/3 continues it as the final call" do
      assert {:ok, _config, %BaseAgentOutputSchema{chat_message: "done"}} =
               BaseAgent.stream(agent("done", %{final_pauses: 1}), "weather?", fn _ -> :ok end)

      assert [_, _, paused_call, continued] = requests()
      assert_continued_final(paused_call, continued)
    end

    test "Turn.Server stores the paused turn and the answer" do
      store = InMemory.new()

      {:ok, srv} =
        Server.start_link(
          session_id: "s-cap-pause",
          config: agent("done", %{final_pauses: 1}),
          store: {InMemory, store},
          registry: {Native, Native.new()}
        )

      assert {:ok, %BaseAgentOutputSchema{chat_message: "done"}} =
               Server.run(srv, %{chat_message: "go"})

      assert {:ok, entries} = InMemory.history(store, "s-cap-pause")

      assert ["user", "assistant", "tool", "assistant", "tool", "user", "assistant", "assistant"] =
               Enum.map(entries, & &1.role)

      assert [_, _, paused_call, continued] = requests()
      assert_continued_final(paused_call, continued)
    end
  end

  test "max_tool_iterations defaults to 20" do
    assert BaseAgent.init(%{client: %CapClient{notify: self()}, model: "m"}).max_tool_iterations ==
             20
  end
end
