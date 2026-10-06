defmodule Normandy.Coordination.AgentMessageTest do
  use ExUnit.Case, async: true

  alias Normandy.Coordination.AgentMessage

  test "new/1 fills an id, a timestamp and defaults; the type is stored as a string" do
    msg = AgentMessage.new(from: "a", to: "b", payload: %{q: 1})

    assert %AgentMessage{from: "a", to: "b", type: "request", payload: %{q: 1}, metadata: %{}} =
             msg

    assert {:ok, _} = UUID.info(msg.id)
    assert msg.timestamp > 0
    assert AgentMessage.new(from: "a", to: "b", type: :broadcast).type == "broadcast"
  end

  test "new/1 requires :from and :to" do
    assert_raise ArgumentError,
                 ~r/^Normandy\.Coordination\.AgentMessage\.new\/1: required :from option not found/,
                 fn -> AgentMessage.new(to: "b") end

    assert_raise ArgumentError,
                 ~r/^Normandy\.Coordination\.AgentMessage\.new\/1: required :to option not found/,
                 fn -> AgentMessage.new(from: "a") end
  end

  test "reply/2 swaps sender and recipient and marks a response" do
    original = AgentMessage.new(from: "a", to: "b")

    assert %AgentMessage{from: "b", to: "a", type: "response", payload: %{ok: true}} =
             AgentMessage.reply(original, %{ok: true})
  end

  test "error/3 swaps sender and recipient and carries the reason and details" do
    original = AgentMessage.new(from: "a", to: "b")

    assert %AgentMessage{
             from: "b",
             to: "a",
             type: "error",
             payload: %{error: "failed", details: %{code: 500}}
           } = AgentMessage.error(original, "failed", %{code: 500})
  end
end
