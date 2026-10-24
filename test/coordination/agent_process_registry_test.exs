defmodule Normandy.Coordination.AgentProcessRegistryTest do
  @moduledoc """
  Task 6.5e: a `:server`-mode `AgentProcess` started without a `:registry` uses a scope
  in Normandy's shared registry, so starting one creates no atom, and two with the same
  agent id never see each other's servers.
  """
  # Counts atoms node-wide: nothing else may run.
  use ExUnit.Case, async: false

  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.PromptSpecification
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Coordination.AgentProcess.ScopedRegistry

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Memory encodes every entry when it is appended (Task 6.1a): the output needs an impl.
  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  defp config do
    %BaseAgentConfig{
      output_schema: %Resp{},
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %PromptSpecification{}
    }
  end

  defp handlers(text) do
    %{
      AgentHandlers.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: text} end
    }
  end

  defp start_run_stop do
    {:ok, pid} =
      AgentProcess.start_link(agent: config(), turn_engine: :server, handlers: handlers("ok"))

    {:ok, _} = AgentProcess.run(pid, "go")
    :ok = AgentProcess.stop(pid)
  end

  test "starting, running and stopping a :server AgentProcess creates no atom" do
    # Warm up: module loading and first-use atoms.
    start_run_stop()
    before = :erlang.system_info(:atom_count)

    for _ <- 1..50, do: start_run_stop()

    assert :erlang.system_info(:atom_count) == before
  end

  test "two processes with the same agent id run separate sessions" do
    {:ok, a} =
      AgentProcess.start_link(
        agent: config(),
        agent_id: "same",
        turn_engine: :server,
        handlers: handlers("from a")
      )

    {:ok, b} =
      AgentProcess.start_link(
        agent: config(),
        agent_id: "same",
        turn_engine: :server,
        handlers: handlers("from b")
      )

    assert {:ok, %Resp{content: "from a"}} = AgentProcess.run(a, "go")
    assert {:ok, %Resp{content: "from b"}} = AgentProcess.run(b, "go")

    %{engine_state: %{session: %{registry: {ScopedRegistry, {_name, scope_a}}}}} =
      :sys.get_state(a)

    %{engine_state: %{session: %{registry: {ScopedRegistry, {_name, scope_b}}}}} =
      :sys.get_state(b)

    assert scope_a != scope_b
  end

  test "a server's entry goes with it" do
    {:ok, pid} =
      AgentProcess.start_link(
        agent: config(),
        agent_id: "gone",
        turn_engine: :server,
        handlers: handlers("ok")
      )

    {:ok, _} = AgentProcess.run(pid, "go")
    %{engine_state: %{session: %{registry: {ScopedRegistry, handle}}}} = :sys.get_state(pid)
    assert {:ok, server} = ScopedRegistry.whereis(handle, "gone")

    ref = Process.monitor(server)
    :ok = AgentProcess.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^server, _reason}

    assert wait_until(fn ->
             ScopedRegistry.whereis(handle, "gone") == :none
           end)
  end
end
