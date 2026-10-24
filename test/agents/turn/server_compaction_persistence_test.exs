defmodule Normandy.Agents.Turn.ServerCompactionPersistenceTest do
  @moduledoc """
  Task 6.2g (Wave 5 deferral, Review Focus #1): `Turn.Server` stores each compaction as
  a `"compaction"` history entry, so a restarted server rebuilds the compacted memory,
  not the full history. A failed snapshot write is logged and the turn goes on.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.{BaseAgentConfig, Turn}
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.{AgentMemory, PromptSpecification}
  alias Normandy.Test.KeepLastCompactor

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # InMemory, except that a "compaction" append returns {:error, :disk_full}.
  defmodule NoSnapshotStore do
    @moduledoc false
    alias Normandy.Behaviours.SessionStore.InMemory

    def append_entry(_h, _sid, %{role: "compaction"}), do: {:error, :disk_full}
    defdelegate append_entry(h, sid, entry), to: InMemory
    defdelegate history(h, sid), to: InMemory
    defdelegate load_turn_state(h, sid), to: InMemory
    defdelegate save_turn_state(h, sid, ts, inflight?), to: InMemory
  end

  defp config(keep) do
    %BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %PromptSpecification{},
      toolset: nil,
      behaviours: %Config{compactor: {KeepLastCompactor, keep: keep, context_window: 200_000}}
    }
  end

  defp start(sid, store) do
    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config(2),
        store: store,
        registry: {Native, Native.new()},
        handlers: %{
          AgentHandlers.non_streaming_handlers()
          | call_llm: fn _config, _state, _request -> %Resp{content: "answer"} end
        }
      )

    srv
  end

  defp chain(memory),
    do:
      memory
      |> AgentMemory.entry_chain()
      |> Enum.map(&{&1.id, &1.parent_id, &1.turn_id, &1.role, &1.content})

  defp memory_of(srv) do
    {_state, data} = :sys.get_state(srv)
    data.config.memory
  end

  test "a restarted server rebuilds the compacted memory the live server had" do
    store = InMemory.new()
    sid = "compaction-restore-#{System.unique_integer([:positive])}"
    srv = start(sid, {InMemory, store})

    for text <- ["one", "two", "three"], do: assert({:ok, _} = Turn.Server.run(srv, text))

    live = memory_of(srv)
    {:ok, stored} = InMemory.history(store, sid)
    assert Enum.count(stored, &(&1.role == "compaction")) == 2
    # Each snapshot records the rounds its turn had made: none here, the turns call no tool.
    assert for(%{role: "compaction", content: c} <- stored, do: c.turn_rounds) == [0, 0]
    assert length(chain(live)) < Enum.count(stored, &(&1.role != "compaction"))

    :ok = :gen_statem.stop(srv)
    restored = memory_of(start(sid, {InMemory, store}))

    assert chain(restored) == chain(live)
    assert restored.head == live.head
    assert restored.current_turn_id == live.current_turn_id

    # The restore fills every entry's cache once (PERF-3): no request re-encodes it.
    for entry <- AgentMemory.entry_chain(restored) do
      assert is_binary(entry.wire) or is_list(entry.wire), "no wire on #{entry.id}"
      assert is_integer(entry.tokens), "no token estimate on #{entry.id}"
    end
  end

  test "a snapshot the store refuses is logged by its tag; the turn succeeds" do
    store = InMemory.new()
    sid = "compaction-refused-#{System.unique_integer([:positive])}"
    srv = start(sid, {NoSnapshotStore, store})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for text <- ["one", "two"], do: assert({:ok, _} = Turn.Server.run(srv, text))
      end)

    assert log =~ ~s|Turn.Server could not store a compaction (session "#{sid}"): :disk_full|
    {:ok, stored} = InMemory.history(store, sid)
    refute Enum.any?(stored, &(&1.role == "compaction"))

    # No compaction was stored, so a restart rebuilds every stored message.
    :ok = :gen_statem.stop(srv)
    restored = memory_of(start(sid, {NoSnapshotStore, store}))
    assert length(chain(restored)) == length(stored)
  end
end
