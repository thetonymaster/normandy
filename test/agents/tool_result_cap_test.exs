defmodule Normandy.Agents.ToolResultCapTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.StreamEvent
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Hooks.ServerGlue
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.TelemetryCapture
  alias Normandy.Tools.Toolset

  @truncated [:normandy, :tool, :result_truncated]

  # A response model Turn.Server finalizes on: no tool_calls -> :completed.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # Calls the "big" tool once, then answers "done" once the conversation holds a result.
  defmodule BigToolClient do
    defstruct options: %{}

    defimpl Normandy.Agents.Model do
      alias Normandy.Agents.ToolCallResponse
      alias Normandy.Components.ToolCall

      def converse(_client, request, _opts) do
        content =
          if Enum.any?(request.messages, &(&1.role == "tool")),
            do: %ToolCallResponse{content: "done", tool_calls: nil},
            else: %ToolCallResponse{
              content: nil,
              tool_calls: [%ToolCall{id: "call_1", name: "big", input: %{}}]
            }

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(_client, request, _opts) do
        events =
          if Enum.any?(request.messages, &(&1.role == "tool")) do
            [
              %{type: "message_start", message: %{"id" => "m2", "role" => "assistant"}},
              %{
                type: "content_block_start",
                content_block: %{"type" => "text", "text" => ""},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "text_delta", "text" => "done"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          else
            [
              %{type: "message_start", message: %{"id" => "m1", "role" => "assistant"}},
              %{
                type: "content_block_start",
                content_block: %{"type" => "tool_use", "id" => "call_1", "name" => "big"},
                index: 0
              },
              %{
                type: "content_block_delta",
                delta: %{"type" => "input_json_delta", "partial_json" => "{}"},
                index: 0
              },
              %{type: "message_stop"}
            ]
          end

        {:ok, Stream.map(events, & &1)}
      end
    end
  end

  defp big_call(id \\ "call_1"), do: %ToolCall{id: id, name: "big", input: %{}}

  defp config(tool, extra \\ %{}) do
    Map.merge(
      %{name: "cap-#{System.unique_integer([:positive])}", toolset: Toolset.new([tool])},
      extra
    )
  end

  defp dispatch(config, call \\ big_call(), pipeline \\ Dispatch.default_pipeline()),
    do: Dispatch.dispatch_one(config, call, pipeline)

  defp note(kept, total), do: "\n[truncated: #{kept} of #{total} chars shown]"

  defp agent(extra) do
    %{
      client: %BigToolClient{},
      model: "m",
      name: "cap-agent-#{System.unique_integer([:positive])}"
    }
    |> Map.merge(extra)
    |> BaseAgent.init()
  end

  defp tool_results(memory) do
    for %{role: "tool", content: %ToolResult{} = result} <- AgentMemory.messages(memory),
        do: result
  end

  describe "Dispatch.finish/3 at the chokepoint" do
    test "the agent cap cuts a long result, ends it with the note, and emits the event" do
      cfg = config(%ReturnTool{output: String.duplicate("a", 25)}, %{max_tool_result_chars: 10})
      ref = TelemetryCapture.attach([@truncated], agent_name: cfg.name)

      assert %ToolResult{tool_call_id: "call_1", is_error: false, output: output} = dispatch(cfg)
      assert output == String.duplicate("a", 10) <> note(10, 25)

      assert_received {:telemetry, ^ref, %{original_chars: 25, kept_chars: 10},
                       %{
                         tool_name: "big",
                         tool_call_id: "call_1",
                         limit_source: :agent,
                         agent_name: agent_name
                       }}

      assert agent_name == cfg.name
    end

    test "a result at the cap is unchanged and emits nothing" do
      cfg = config(%ReturnTool{output: String.duplicate("a", 10)}, %{max_tool_result_chars: 10})
      ref = TelemetryCapture.attach([@truncated], agent_name: cfg.name)

      assert %ToolResult{output: "aaaaaaaaaa", is_error: false} = dispatch(cfg)
      refute_received {:telemetry, ^ref, _, _}
    end

    test "a config without the key caps at 100_000" do
      cfg = %{
        name: "bare",
        toolset: Toolset.new([%ReturnTool{output: String.duplicate("b", 100_001)}])
      }

      assert %ToolResult{output: output} = dispatch(cfg)
      assert output == String.duplicate("b", 100_000) <> note(100_000, 100_001)
    end

    test "the tool's max_result_chars wins over the agent's" do
      toolset =
        Toolset.register(Toolset.new(), %ReturnTool{output: "0123456789"}, max_result_chars: 4)

      cfg = %{
        name: "t-#{System.unique_integer([:positive])}",
        toolset: toolset,
        max_tool_result_chars: 8
      }

      ref = TelemetryCapture.attach([@truncated], agent_name: cfg.name)

      assert %ToolResult{output: "0123" <> rest} = dispatch(cfg)
      assert rest == note(4, 10)
      assert_received {:telemetry, ^ref, %{kept_chars: 4}, %{limit_source: :tool}}
    end

    test "a tool registered with max_result_chars: nil is never cut" do
      long = String.duplicate("c", 50)
      toolset = Toolset.register(Toolset.new(), %ReturnTool{output: long}, max_result_chars: nil)

      assert %ToolResult{output: ^long} =
               dispatch(%{name: "a", toolset: toolset, max_tool_result_chars: 10})
    end

    test "an agent cap of nil turns the cap off" do
      long = String.duplicate("c", 200_000)

      assert %ToolResult{output: ^long} =
               dispatch(config(%ReturnTool{output: long}, %{max_tool_result_chars: nil}))
    end

    # Review Focus #4: a cut on a grapheme boundary, multibyte tail included.
    test "the cut keeps a ZWJ emoji family whole and the text valid UTF-8" do
      family = "👨‍👩‍👧"
      text = String.duplicate("a", 9) <> family <> "é" <> "ü"
      cfg = config(%ReturnTool{output: text}, %{max_tool_result_chars: 10})

      assert %ToolResult{output: output} = dispatch(cfg)
      assert output == String.duplicate("a", 9) <> family <> note(10, 12)
      assert String.valid?(output)
      [kept, _note] = String.split(output, "\n[truncated:")
      assert String.length(kept) == 10
      assert String.ends_with?(kept, family)
    end

    test "a text over the cap in bytes but not in characters is unchanged" do
      text = String.duplicate("👨‍👩‍👧", 3)

      assert %ToolResult{output: ^text} =
               dispatch(config(%ReturnTool{output: text}, %{max_tool_result_chars: 3}))
    end

    test "a map output is cut as its JSON text" do
      output = %{"k" => String.duplicate("x", 20)}
      cfg = config(%ReturnTool{output: output}, %{max_tool_result_chars: 10})

      assert %ToolResult{output: text, is_error: false} = dispatch(cfg)
      assert text == ~s({"k":"xxxx) <> note(10, 28)
    end

    test "an error result is capped too" do
      cfg =
        config(%ReturnTool{output: String.duplicate("e", 30), error: true}, %{
          max_tool_result_chars: 10
        })

      assert %ToolResult{is_error: true, output: output} = dispatch(cfg)
      assert output =~ ~r/\A.{10}\n\[truncated: 10 of \d+ chars shown\]\z/su
    end

    test "a denial built by classify/3 (a toolset miss) is capped" do
      cfg = config(%ReturnTool{}, %{max_tool_result_chars: 10})
      call = %ToolCall{id: "m1", name: "missing", input: %{}}

      assert %ToolResult{tool_call_id: "m1", is_error: true, output: output} = dispatch(cfg, call)
      assert output =~ ~r/\A.{10}\n\[truncated: 10 of \d+ chars shown\]\z/su
    end

    test "a budget denial is capped" do
      cfg = config(%ReturnTool{}, %{max_tool_result_chars: 10})

      pipeline = %{
        Dispatch.default_pipeline()
        | budget_check_fn: fn _config, _call -> {:error, String.duplicate("r", 40)} end
      }

      assert %ToolResult{is_error: true, output: output} = dispatch(cfg, big_call(), pipeline)
      assert output =~ ~r/\A.{10}\n\[truncated: 10 of \d+ chars shown\]\z/su
    end

    test "after_tool and the after-hooks see the whole output; the cap runs once, last" do
      test_pid = self()
      cfg = config(%ReturnTool{output: String.duplicate("h", 30)}, %{max_tool_result_chars: 10})

      pipeline = %{
        Dispatch.default_pipeline()
        | after_tool: fn _config, _call, result ->
            send(test_pid, {:after_tool, String.length(result.output)})
            result
          end,
          after_hooks: [
            fn _config, _call, result ->
              send(test_pid, {:after_hook, String.length(result.output)})
              %{result | output: result.output <> "!!"}
            end
          ]
      }

      assert %ToolResult{output: output} = dispatch(cfg, big_call(), pipeline)
      assert_received {:after_tool, 30}
      assert_received {:after_hook, 30}
      assert output == String.duplicate("h", 10) <> note(10, 32)
    end

    test "an output that is not valid UTF-8 becomes an error result" do
      assert %ToolResult{
               is_error: true,
               output: "the tool ran, but its output is not valid UTF-8 text"
             } = dispatch(config(%ReturnTool{output: <<"ok", 255, 254>>}))
    end
  end

  describe "every path stores the capped result" do
    test "BaseAgent.run/3 keeps the capped result in memory" do
      config =
        agent(%{max_tool_result_chars: 10})
        |> BaseAgent.register_tool(%ReturnTool{output: String.duplicate("s", 40)})

      assert {:ok, config, _output} = BaseAgent.run(config, %{chat_message: "go"})

      assert [%ToolResult{tool_call_id: "call_1", output: output}] = tool_results(config.memory)
      assert output == String.duplicate("s", 10) <> note(10, 40)
    end

    test "BaseAgent.stream/3 emits and stores the capped result" do
      test_pid = self()

      config =
        agent(%{max_tool_result_chars: 10})
        |> BaseAgent.register_tool(%ReturnTool{output: String.duplicate("s", 40)})

      callback = fn
        %StreamEvent{type: :tool_result, data: result} -> send(test_pid, {:streamed, result})
        _event -> :ok
      end

      assert {:ok, config, _output} = BaseAgent.stream(config, %{chat_message: "go"}, callback)

      expected = String.duplicate("s", 10) <> note(10, 40)
      assert_received {:streamed, %ToolResult{output: ^expected}}
      assert [%ToolResult{output: ^expected}] = tool_results(config.memory)
    end

    test "Turn.Server persists the capped result" do
      store = InMemory.new()
      sid = "cap-#{System.unique_integer([:positive])}"
      calls = :counters.new(1, [])

      call_llm = fn _config, _state, _request ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: %Resp{content: "", tool_calls: [big_call("t1")]},
          else: %Resp{content: "done", tool_calls: nil}
      end

      config = %{
        BaseAgent.init(%{client: %BigToolClient{}, model: "m", max_tool_result_chars: 10})
        | output_schema: %Resp{},
          input_schema: nil,
          toolset: Toolset.new([%ReturnTool{output: String.duplicate("s", 40)}])
      }

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: config,
          store: {InMemory, store},
          registry: {Native, Native.new()},
          handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
        )

      assert {:ok, %Resp{content: "done"}} = Turn.Server.run(srv, "go")
      {:ok, entries} = InMemory.history(store, sid)

      assert [%ToolResult{tool_call_id: "t1", output: output}] =
               for(%{role: "tool", content: %ToolResult{} = r} <- entries, do: r)

      assert output == String.duplicate("s", 10) <> note(10, 40)
    end

    test "ServerGlue caps the results it rewrites through after_tool" do
      config =
        BaseAgent.init(%{
          client: %BigToolClient{},
          model: "m",
          max_tool_result_chars: 10,
          toolset: Toolset.new([%ReturnTool{}]),
          behaviours: %Normandy.Behaviours.Config{hooks: [{Normandy.Test.Hooks.Probe, []}]}
        })

      long = %ToolResult{tool_call_id: "t1", output: String.duplicate("i", 30), is_error: true}
      expected = String.duplicate("i", 10) <> note(10, 30)

      assert %ToolResult{tool_call_id: "t1", output: ^expected} =
               ServerGlue.after_tool(config, big_call("t1"), long)

      state = Turn.new(max_iterations: 1)

      assert {_state, [{:append_message, "tool", %ToolResult{output: ^expected}}]} =
               ServerGlue.after_tool_built(
                 config,
                 [big_call("t1")],
                 {state, [{:append_message, "tool", long}]}
               )
    end
  end
end
