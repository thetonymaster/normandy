defmodule Normandy.Agents.Turn.ServerAppendEncodingTest do
  @moduledoc """
  Task 6.1a (R1): memory encodes a message when it is appended, so under `Turn.Server`
  content that cannot be encoded fails the turn as a crashed `:append` before the store
  holds it, and the server stays up.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig
  alias Normandy.TurnError

  defmodule NoEncoding do
    @moduledoc false
    defstruct content: "", tool_calls: nil
  end

  defp start(answer, config \\ TurnConfig.build()) do
    sid = "enc-#{System.unique_integer([:positive])}"
    store = InMemory.new()
    handlers = %{BaseAgent.non_streaming_handlers() | call_llm: fn _c, _s, _r -> answer end}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: handlers,
        subscriber: nil
      )

    {srv, store, sid}
  end

  test "an answer that cannot be encoded fails as a crashed :append; the store keeps the input only" do
    config = %{TurnConfig.build() | output_schema: %NoEncoding{}}
    {srv, store, sid} = start(%NoEncoding{content: "x"}, config)

    assert {:error,
            %TurnError{
              type: :handler_crashed,
              handler: :append,
              reason: %Protocol.UndefinedError{protocol: Normandy.Components.BaseIOSchema}
            }} = Turn.Server.run(srv, "hello")

    assert {:ok, [%{role: "user", content: "hello"}]} = InMemory.history(store, sid)
    assert Process.alive?(srv)
  end

  test "an input that cannot be encoded fails as a crashed :append before anything is stored" do
    {srv, store, sid} = start(%TurnConfig.Resp{content: "fine"})

    assert {:error,
            %TurnError{
              type: :handler_crashed,
              handler: :append,
              reason: %Protocol.UndefinedError{protocol: Normandy.Components.BaseIOSchema}
            }} = Turn.Server.run(srv, %NoEncoding{content: "x"})

    assert {:ok, []} = InMemory.history(store, sid)
    assert {:ok, %TurnConfig.Resp{content: "fine"}} = Turn.Server.run(srv, "hello")
  end
end
