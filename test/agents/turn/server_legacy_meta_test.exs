defmodule Normandy.Agents.Turn.ServerLegacyMetaTest do
  # A turn state a store kept as a native term (Mnesia) before schema structs dropped
  # __meta__ loads without it.
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.{BaseAgent, BaseAgentOutputSchema, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.FakeClient

  test "a saved Turn.State holding a legacy __meta__ loses it on load" do
    store = InMemory.new()
    sid = "legacy-meta-#{System.unique_integer([:positive])}"

    legacy_meta = %{__struct__: Normandy.Metadata, state: :built, schema: BaseAgentOutputSchema}
    legacy = Map.put(%BaseAgentOutputSchema{chat_message: "old"}, :__meta__, legacy_meta)

    :ok =
      InMemory.save_turn_state(
        store,
        sid,
        %Turn.State{status: :stopped, final_response: legacy},
        false
      )

    config =
      BaseAgent.init(%{client: FakeClient.new([]), model: "m", max_tokens: 64})

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()}
      )

    {_state, data} = :sys.get_state(srv)

    assert %BaseAgentOutputSchema{chat_message: "old"} = data.turn_state.final_response
    refute Map.has_key?(data.turn_state.final_response, :__meta__)
  end
end
