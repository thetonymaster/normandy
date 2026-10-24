defmodule Normandy.Agents.Turn.ServerRunUsageTest do
  @moduledoc """
  A custom `:handlers` set's `call_llm` under `Turn.Server` gets the run's usage
  accumulator as `request[:run_usage]`, as BaseAgent's own `call_llm` does: the server adds
  it to every call request before calling the set.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver.Handlers
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig

  test "a custom call_llm receives request[:run_usage]" do
    test_pid = self()

    call_llm = fn _config, _state, request ->
      send(test_pid, {:request, request})
      %TurnConfig.Resp{content: "answer"}
    end

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "run-usage-#{System.unique_integer([:positive])}",
        config: TurnConfig.build(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        handlers: %{Handlers.default() | call_llm: call_llm},
        subscriber: nil
      )

    assert {:ok, _output} = Turn.Server.run(srv, "hello")
    assert_received {:request, %{run_usage: run_usage}}
    refute is_nil(run_usage)
  end
end
