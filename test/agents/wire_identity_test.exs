defmodule Normandy.Agents.WireIdentityTest do
  @moduledoc """
  Task 6.1 (PERF-3, R1): caching each message's encoding changes no request.

  One scripted conversation (an io_schema input, a tool round with thinking and two
  parallel tool results, one of them JSON, a system prompt change that makes earlier
  thinking stale, and a compaction) is sent through `BaseAgent.run/3`, `BaseAgent.stream/3`
  and `Turn.Server`, with prompt caching off and on. Every request body must equal the one
  recorded from the code before Task 6.1 (`d624fbf`) in `test/fixtures/wire_identity/`:
  every value, every array in its order. Bodies are compared decoded, because the order
  of a JSON object's keys is not stable between VM runs (an atom-keyed map iterates in
  atom-table order since OTP 26: a tool_result block's `is_error` and `tool_use_id` swap
  places from one run to the next on the same code).

  To record (once, on the code before Task 6.1a):
  `NORMANDY_RECORD_WIRE=1 mix test test/agents/wire_identity_test.exs`. A recording run
  writes the fixtures and fails on purpose, so it can never pass a gate. Re-recorded once
  since, for the system prompt's `# INPUT SCHEMA` section (AX-29), and edited by hand for the
  Role section sent as prose: only `system` changed each time.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn.Server
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.PromptSpecification
  alias Normandy.Test.FakeTool
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  @fixtures Path.expand("../fixtures/wire_identity", __DIR__)
  @record System.get_env("NORMANDY_RECORD_WIRE") == "1"

  defmodule Question do
    use Normandy.Schema

    io_schema "A question about a city" do
      field(:text, :string, required: true)
      field(:lang, :string, default: "en")
    end
  end

  # A context provider whose text the test changes between turns: the system prompt,
  # and so the prefix key, changes, and earlier thinking becomes stale.
  defmodule Phase do
    @moduledoc false
    defstruct [:agent]

    defimpl Normandy.Components.ContextProvider do
      def title(_phase), do: "Phase"
      def get_info(%{agent: agent}), do: Agent.get(agent, & &1)
    end
  end

  # Each reply as content blocks and a stop reason; json_replies/0 and sse_replies/0
  # render them.
  @replies [
    {[
       %{"type" => "thinking", "thinking" => "plan one", "signature" => "sig-1"},
       %{"type" => "text", "text" => "Checking."},
       %{
         "type" => "tool_use",
         "id" => "t1",
         "name" => "weather",
         "input" => %{"city" => "Paris"}
       },
       %{"type" => "tool_use", "id" => "t2", "name" => "facts", "input" => %{}}
     ], "tool_use"},
    {[%{"type" => "text", "text" => "Paris is sunny."}], "end_turn"},
    {[
       %{"type" => "thinking", "thinking" => "plan two", "signature" => "sig-2"},
       %{"type" => "tool_use", "id" => "t3", "name" => "weather", "input" => %{"city" => "Lyon"}}
     ], "tool_use"},
    {[%{"type" => "text", "text" => "Lyon is cloudy."}], "end_turn"},
    {[%{"type" => "text", "text" => "Done."}], "end_turn"}
  ]

  @turns [
    {"phase one", %{text: "Weather in Paris?", lang: "en"}},
    {"phase two", %{text: "And Lyon?", lang: "fr"}},
    {"phase two", %{text: "Thanks, that is all.", lang: "en"}}
  ]

  defp json_replies, do: Enum.map(@replies, fn {blocks, stop} -> {:json, blocks, stop} end)

  defp sse_replies do
    @replies
    |> Enum.with_index()
    |> Enum.map(fn {{blocks, stop}, i} ->
      events = blocks |> Enum.with_index() |> Enum.flat_map(fn {b, j} -> sse_block(j, b) end)
      {:sse, WireScript.message("msg_#{i}", events, stop)}
    end)
  end

  defp sse_block(j, %{"type" => "thinking", "thinking" => t, "signature" => s}) do
    WireScript.block(j, %{"type" => "thinking", "thinking" => ""}, [
      %{"type" => "thinking_delta", "thinking" => t},
      %{"type" => "signature_delta", "signature" => s}
    ])
  end

  defp sse_block(j, %{"type" => "text", "text" => t}),
    do:
      WireScript.block(j, %{"type" => "text", "text" => ""}, [
        %{"type" => "text_delta", "text" => t}
      ])

  defp sse_block(j, %{"type" => "tool_use", "input" => input} = b) do
    WireScript.block(j, %{b | "input" => %{}}, [
      %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}
    ])
  end

  # The compactor's window (270 tokens of room) is crossed only at turn 3's start.
  defp agent(client, phase) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      max_tokens: 1024,
      input_schema: %Question{},
      prompt_specification: %PromptSpecification{
        background: ["You answer questions about cities."],
        context_providers: %{phase: %Phase{agent: phase}}
      },
      toolset:
        Toolset.new([
          %FakeTool{name: "weather"},
          %ReturnTool{name: "facts", output: %{"population" => 2_100_000, "tags" => ["capital"]}}
        ]),
      # The window compacts once, before the fifth request: 1_430 to 1_460 does. The
      # compactor counts the system prompt and tools against it (AX-12), which is why it
      # is not the 1_270 the fixtures were recorded with; the requests are unchanged.
      behaviours: %Normandy.Behaviours.Config{
        compactor: {Compactor.WindowManager, context_window: 1_445, reserved_tokens: 1_000}
      }
    })
  end

  # The scenario's request bodies, decoded, in call order.
  defp run_turns(path, caching) do
    {:ok, phase} = Agent.start_link(fn -> "" end)
    replies = if path == :stream, do: sse_replies(), else: json_replies()
    client = WireScript.client(replies, %{enable_caching: caching})
    :ok = drive(path, agent(client, phase), phase)

    for n <- 0..(length(@replies) - 1) do
      assert_received {:wire_body, ^n, body}
      body
    end
  end

  defp drive(:server, config, phase) do
    {:ok, srv} =
      Server.start_link(
        session_id: "wire-identity-#{System.unique_integer([:positive])}",
        config: config,
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    for {text, input} <- @turns do
      Agent.update(phase, fn _ -> text end)
      {:ok, _out} = Server.run(srv, input)
    end

    :ok
  end

  defp drive(path, config, phase) do
    _final =
      Enum.reduce(@turns, config, fn {text, input}, config ->
        Agent.update(phase, fn _ -> text end)
        {:ok, config, _out} = turn(path, config, input)
        config
      end)

    :ok
  end

  defp turn(:run, config, input), do: BaseAgent.run(config, input)
  defp turn(:stream, config, input), do: BaseAgent.stream(config, input, fn _event -> :ok end)

  for path <- [:run, :stream, :server], caching <- [false, true] do
    @tag path: path, caching: caching
    test "#{path}, caching #{caching}: every request body is identical to the fixture",
         %{path: path, caching: caching} do
      bodies = run_turns(path, caching)
      file = Path.join(@fixtures, "#{path}-caching-#{caching}.json")

      if @record do
        File.mkdir_p!(@fixtures)
        File.write!(file, Jason.encode_to_iodata!(bodies, pretty: true))
        flunk("recorded #{length(bodies)} bodies to #{file}; rerun without NORMANDY_RECORD_WIRE")
      end

      expected = file |> File.read!() |> Jason.decode!()
      assert length(bodies) == length(expected)

      for {body, want, n} <- Enum.zip([bodies, expected, 0..(length(expected) - 1)]) do
        assert body == want, "request #{n} differs from #{file}"
      end
    end
  end

  for path <- [:run, :stream, :server] do
    @tag path: path
    test "#{path}: the scenario reaches every case it is meant to pin", %{path: path} do
      [_first, _second, third, fourth, fifth] =
        run_turns(path, false)

      # Turn 2's first call drops turn 1's stale thinking; its second call keeps turn 2's.
      refute inspect(third["messages"]) =~ "sig-1"
      assert inspect(fourth["messages"]) =~ "sig-2"
      # Only turn 3 starts compacted: its first message is no longer turn 1's question.
      assert inspect(hd(fourth["messages"])) =~ "Weather in Paris?"
      refute inspect(hd(fifth["messages"])) =~ "Weather in Paris?"
      # A JSON tool result and an io_schema input are on the wire.
      assert inspect(fourth["messages"]) =~ ~s(\\"population\\":2100000)
      assert inspect(fourth["messages"]) =~ ~s(\\"lang\\":\\"fr\\")
    end
  end
end
