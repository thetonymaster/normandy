defmodule Normandy.Agents.LinearHistoryTest do
  @moduledoc """
  Task 6.1d (PERF-3/B1, R1): Normandy encodes each message once, however long the
  conversation grows. Over N turns, K seeded messages stay at K encodings and every tool
  result costs the same number of encodings, on `BaseAgent.run/3`, `BaseAgent.stream/3`
  and `Turn.Session` (whose rehydration encodes each stored message once more), with and
  without a compactor. Before Task 6.1 the counts grew with N² (`model_content/1` ran
  100, 400 and 1600 times over 10, 20 and 40 turns; four times that with
  `Compactor.WindowManager`).

  Counted: `BaseIOSchema.to_json/1` of `Normandy.Test.CountingContent` (memory content)
  and `Jason.Encoder.encode/2` of `CountingOutput` (a tool's output: Dispatch encodes it
  four times, in `execute/4`'s and `finish/3`'s encodability checks, `wrap_output/2` and
  the result cap, and memory once, when the result is appended).
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Test.CountingContent
  alias Normandy.Test.ReturnTool
  alias Normandy.Test.WireScript
  alias Normandy.Tools.Toolset

  defmodule CountingOutput do
    @moduledoc false
    defstruct [:ref]

    defimpl Jason.Encoder do
      def encode(%{ref: ref}, opts) do
        :counters.add(ref, 1, 1)
        Jason.Encode.map(%{"rows" => 3}, opts)
      end
    end
  end

  # Encodings per tool result: Dispatch's four, memory's one. Constant in N.
  @per_result 5
  @seeded 6
  @no_compaction {Compactor.WindowManager, context_window: 1_000_000, reserved_tokens: 1_000}

  defp seeded_memory(ref) do
    Enum.reduce(1..@seeded, AgentMemory.new_memory(), fn i, m ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      AgentMemory.add_message(m, role, CountingContent.new(ref, "seeded message #{i}"))
    end)
  end

  # One tool round per turn: a tool_use, then the answer.
  defp blocks(turn) do
    [
      {[%{"type" => "tool_use", "id" => "t#{turn}", "name" => "rows", "input" => %{}}],
       "tool_use"},
      {[%{"type" => "text", "text" => "answer #{turn}"}], "end_turn"}
    ]
  end

  defp json_replies(turns),
    do: for(t <- turns, {content, stop} <- blocks(t), do: {:json, content, stop})

  defp sse_replies(turns) do
    for t <- turns, {[block], stop} <- blocks(t) do
      events =
        case block do
          %{"type" => "tool_use"} ->
            WireScript.block(0, block, [%{"type" => "input_json_delta", "partial_json" => "{}"}])

          %{"type" => "text", "text" => text} ->
            WireScript.block(0, %{"type" => "text", "text" => ""}, [
              %{"type" => "text_delta", "text" => text}
            ])
        end

      {:sse, WireScript.message("msg_#{t}", events, stop)}
    end
  end

  defp agent(client, out, memory, compactor) do
    BaseAgent.init(%{
      client: client,
      model: "claude-opus-5-5",
      max_tokens: 1_000,
      memory: memory,
      toolset: Toolset.new([%ReturnTool{name: "rows", output: %CountingOutput{ref: out}}]),
      behaviours: %Normandy.Behaviours.Config{compactor: compactor}
    })
  end

  defp counters, do: {CountingContent.counter(), CountingContent.counter()}

  for path <- [:run, :stream],
      compactor <- [:none, :window_manager],
      turns <- [1, 8] do
    @tag path: path, compactor: compactor, turns: turns
    test "#{path}, compactor #{compactor}, #{turns} turns: each message is encoded once", %{
      path: path,
      compactor: compactor,
      turns: turns
    } do
      {seeded, out} = counters()
      compactor = if compactor == :none, do: {Compactor.NoOp, []}, else: @no_compaction

      client =
        case path do
          :run -> WireScript.client(json_replies(1..turns))
          :stream -> WireScript.client(sse_replies(1..turns))
        end

      config = agent(client, out, seeded_memory(seeded), compactor)

      Enum.reduce(1..turns, config, fn t, config ->
        {:ok, config, _} =
          case path do
            :run -> BaseAgent.run(config, "question #{t}")
            :stream -> BaseAgent.stream(config, "question #{t}", fn _event -> :ok end)
          end

        config
      end)

      assert CountingContent.count(seeded) == @seeded
      assert CountingContent.count(out) == @per_result * turns
    end
  end

  test "a compaction during the conversation encodes no kept message again" do
    {seeded, out} = counters()
    turns = 8
    # Small enough that the seeded messages are cut once the conversation grows.
    compactor = {Compactor.WindowManager, context_window: 1_150, reserved_tokens: 1_000}

    config =
      agent(WireScript.client(json_replies(1..turns)), out, seeded_memory(seeded), compactor)

    final =
      Enum.reduce(1..turns, config, fn t, config ->
        {:ok, config, _} = BaseAgent.run(config, "question #{t}")
        config
      end)

    refute Enum.any?(
             AgentMemory.entry_chain(final.memory),
             &match?(%Entry{content: %CountingContent{}}, &1)
           )

    assert CountingContent.count(seeded) == @seeded
    assert CountingContent.count(out) == @per_result * turns
  end

  for turns <- [1, 8] do
    @tag turns: turns
    test "Turn.Session, #{turns} turns: each message is encoded once, and once more per rehydration",
         %{turns: turns} do
      {seeded, out} = counters()
      store = InMemory.new()
      reg = Native.new()
      {:ok, sup} = Turn.Supervisor.start_link([])
      sid = "linear-#{System.unique_integer([:positive])}"

      # The server's memory is the store's history, so the seeded messages go there.
      for entry <- AgentMemory.entry_chain(seeded_memory(seeded)) do
        {:ok, _} = InMemory.append_entry(store, sid, %{entry | wire: nil, tokens: nil})
      end

      seed_encodings = CountingContent.count(seeded)

      session =
        Turn.Session.new(
          session_id: sid,
          config:
            agent(
              WireScript.client(json_replies(1..(turns + 1))),
              out,
              AgentMemory.new_memory(),
              @no_compaction
            ),
          store: {InMemory, store},
          registry: {Native, reg},
          supervisor: sup
        )

      for t <- 1..turns, do: assert({:ok, _} = Turn.Session.run(session, "question #{t}"))

      assert CountingContent.count(seeded) == seed_encodings + @seeded
      assert CountingContent.count(out) == @per_result * turns

      # A restart rebuilds the memory from the store: every stored message once more.
      {:ok, pid} = Native.whereis(reg, sid)
      Process.exit(pid, :kill)
      assert wait_until(fn -> match?({:ok, new} when new != pid, Native.whereis(reg, sid)) end)

      assert {:ok, _} = Turn.Session.run(session, "question #{turns + 1}")
      assert CountingContent.count(seeded) == seed_encodings + 2 * @seeded
      # turns results rehydrated once each, plus the new turn's result.
      assert CountingContent.count(out) == @per_result * turns + turns + @per_result
    end
  end
end
