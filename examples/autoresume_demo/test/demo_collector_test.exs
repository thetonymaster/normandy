defmodule AutoresumeDemo.DemoCollectorTest do
  use ExUnit.Case, async: true

  alias AutoresumeDemo.DemoCollector, as: C
  alias Normandy.Agents.Turn

  test "derives step/total/status from a turn state and a located node" do
    ts = %Turn.State{status: :steering, iterations_left: 2, max_iterations: 7}
    view = C.agent_view("s1", {:located, :worker_2@h}, {:ok, ts}, %{})
    assert view.id == "s1"
    assert view.node == :worker_2@h
    assert view.status == "running"
    assert view.step == 5
    assert view.total == 7
  end

  test "marks a session offline when not registered but still non-terminal" do
    ts = %Turn.State{status: :steering, iterations_left: 2, max_iterations: 7}
    view = C.agent_view("s1", :unlocated, {:ok, ts}, %{})
    assert view.status == "offline"
  end

  test "flags resumed_from when the node changed since last seen on a different node" do
    ts = %Turn.State{status: :steering, iterations_left: 1, max_iterations: 7}
    prev = %{"s1" => :worker_1@h}
    view = C.agent_view("s1", {:located, :worker_3@h}, {:ok, ts}, prev)
    assert view.resumed_from == :worker_1@h
  end

  test "terminal turn states are reported done" do
    ts = %Turn.State{status: :stopped, iterations_left: 0, max_iterations: 7}
    view = C.agent_view("s1", :unlocated, {:ok, ts}, %{})
    assert view.status == "done"
  end

  test "an unreadable turn state reads offline even when the session is located" do
    view = C.agent_view("s1", {:located, :worker_2@h}, {:error, :not_found}, %{})
    assert view.status == "offline"
    assert view.current_tool == nil
    assert view.step == nil
    assert view.total == nil
  end

  test "current_tool is the pending tool name, and nil when no tool is pending" do
    base = %Turn.State{status: :steering, iterations_left: 2, max_iterations: 7}
    pending = %{base | pending_calls: [%{name: "research_step"}]}
    located = {:located, :worker_2@h}
    assert C.agent_view("s1", located, {:ok, pending}, %{}).current_tool == "research_step"
    assert C.agent_view("s1", located, {:ok, base}, %{}).current_tool == nil
  end
end
