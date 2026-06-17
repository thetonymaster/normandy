defmodule Normandy.Agents.Turn.SessionTest do
  use ExUnit.Case, async: false
  alias Normandy.Agents.Turn

  # A local response struct for stubbing call_llm in Session tests.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # A store whose history/2 reports a genuine fault (a contract-permitted
  # {:error, _}), used to prove rehydration propagates it instead of crashing.
  defmodule FaultyStore do
    def load_turn_state(_handle, _sid), do: :error
    def history(_handle, _sid), do: {:error, :store_unavailable}
  end

  defp session_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      tool_registry: nil
    }
  end

  test "supervisor starts a Turn.Server child as transient" do
    {:ok, sup} = Turn.Supervisor.start_link([])

    {:ok, pid} =
      Turn.Supervisor.start_server(sup,
        session_id: "x",
        config: nil,
        store:
          {Normandy.Behaviours.SessionStore.InMemory,
           Normandy.Behaviours.SessionStore.InMemory.new()},
        registry:
          {Normandy.Behaviours.SessionRegistry.Native,
           Normandy.Behaviours.SessionRegistry.Native.new()}
      )

    assert is_pid(pid)
    assert [{:undefined, ^pid, :worker, _}] = DynamicSupervisor.which_children(sup)
  end

  test "routes to a live session, else rehydrates turn state + memory from the store" do
    alias Normandy.Behaviours.SessionStore.InMemory
    alias Normandy.Behaviours.SessionRegistry.Native

    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])

    # Pre-seed the store with a prior conversation entry (simulating a passivated session).
    {:ok, _} =
      InMemory.append_entry(store, "sess", %Normandy.Components.AgentMemory.Entry{
        turn_id: "t0",
        role: "user",
        content: "earlier"
      })

    opts = [
      session_id: "sess",
      config: session_config(),
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      handlers: %{
        Normandy.Agents.BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %Resp{content: "ok"} end
      }
    ]

    assert {:ok, %{content: "ok"}} = Turn.Session.run(opts, "now")
    # Second call routes to the SAME live pid (no new child).
    assert {:ok, _} = Turn.Session.run(opts, "again")
    assert length(DynamicSupervisor.which_children(sup)) == 1
  end

  test "approve/2 returns {:error, :no_session} for an unknown session" do
    alias Normandy.Behaviours.SessionRegistry.Native

    opts = [session_id: "ghost", registry: {Native, Native.new()}]

    # No live session exists, so approval cannot succeed and must not boot one.
    assert {:error, :no_session} = Turn.Session.approve(opts, %{})
  end

  test "rehydration preserves the configured memory cap (max_messages)" do
    alias Normandy.Behaviours.SessionStore.InMemory
    alias Normandy.Behaviours.SessionRegistry.Native

    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])

    {:ok, _} =
      InMemory.append_entry(store, "capped", %Normandy.Components.AgentMemory.Entry{
        turn_id: "t0",
        role: "user",
        content: "earlier"
      })

    config = %{session_config() | memory: Normandy.Components.AgentMemory.new_memory(7)}

    opts = [
      session_id: "capped",
      config: config,
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      handlers: %{
        Normandy.Agents.BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %Resp{content: "ok"} end
      }
    ]

    assert {:ok, _} = Turn.Session.run(opts, "now")

    {:ok, pid} = Native.whereis(reg, "capped")
    {_state, data} = :sys.get_state(pid)
    assert data.config.memory.max_messages == 7
  end

  test "run/2 returns {:error, reason} when history/2 faults during rehydration" do
    alias Normandy.Behaviours.SessionRegistry.Native

    {:ok, sup} = Turn.Supervisor.start_link([])

    opts = [
      session_id: "faulty",
      config: session_config(),
      store: {FaultyStore, :ignored},
      registry: {Native, Native.new()},
      supervisor: sup
    ]

    # A store fault must surface as run/2's error tuple, not a caller crash.
    assert {:error, :store_unavailable} = Turn.Session.run(opts, "hello")
  end
end
