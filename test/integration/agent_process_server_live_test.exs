defmodule Normandy.Integration.AgentProcessServerLiveTest do
  @moduledoc """
  Live coverage for `AgentProcess` `:server` mode (Phase 6 durable turn engine).

  Drives ONE real Claude turn through `Turn.Session`/`Turn.Server` and verifies
  store-authoritative reconstruction via `get_agent/1`. Tagged `:integration`, so
  it runs only with a real key (`API_KEY` / `ANTHROPIC_API_KEY`) and is excluded
  from the default `mix test` run.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Components.AgentMemory
  alias NormandyTest.Support.NormandyIntegrationHelper, as: H

  defp supplied_infra do
    {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
    [store: {InMemory, InMemory.new()}, registry: {Native, Native.new()}, supervisor: sup]
  end

  test ":server mode drives a real Claude turn end-to-end and persists to the store" do
    client = H.create_real_client()

    config =
      BaseAgent.init(%{
        client: client,
        model: H.default_model(),
        temperature: 0.0,
        max_tokens: 64
      })

    {:ok, pid} =
      AgentProcess.start_link(
        [agent: config, turn_engine: :server, agent_id: "live-server"] ++ supplied_infra()
      )

    # The durable path completes a real turn without error.
    assert {:ok, result} = AgentProcess.run(pid, "Reply with exactly the single word: pong")
    assert result != nil

    # Store-authoritative reconstruction: the user message round-trips through the
    # SessionStore (the Phase 6 headline).
    agent = AgentProcess.get_agent(pid)
    contents = Enum.map(AgentMemory.entry_chain(agent.memory), & &1.content)

    assert Enum.any?(contents, fn c ->
             c == %{chat_message: "Reply with exactly the single word: pong"}
           end),
           "expected the user message to be reconstructed from the store; got: #{inspect(contents)}"

    :ok = AgentProcess.stop(pid)
  end
end
