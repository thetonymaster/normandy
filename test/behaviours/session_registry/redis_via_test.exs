defmodule Normandy.Behaviours.SessionRegistry.Redis.ViaTest do
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionRegistry.Redis
  alias Normandy.Behaviours.SessionRegistry.Redis.Via

  setup do
    {:ok, owner: Redis.new(), sid: "via-#{System.unique_integer([:positive])}"}
  end

  test "register_name answers :yes, then :no for a taken name", %{owner: owner, sid: sid} do
    assert Via.register_name({owner, sid}, self()) == :yes
    assert Via.register_name({owner, sid}, spawn(fn -> :ok end)) == :no
  end

  test "whereis_name returns the pid, or :undefined", %{owner: owner, sid: sid} do
    assert Via.whereis_name({owner, sid}) == :undefined
    :yes = Via.register_name({owner, sid}, self())
    assert Via.whereis_name({owner, sid}) == self()
  end

  test "unregister_name frees the name", %{owner: owner, sid: sid} do
    :yes = Via.register_name({owner, sid}, self())
    assert Via.unregister_name({owner, sid}) == :ok
    assert Via.whereis_name({owner, sid}) == :undefined
  end

  test "send delivers to the registered pid", %{owner: owner, sid: sid} do
    :yes = Via.register_name({owner, sid}, self())
    Via.send({owner, sid}, :hello)
    assert_receive :hello
  end

  test "send to an unregistered name raises badarg", %{owner: owner, sid: sid} do
    assert_raise ArgumentError, fn -> Via.send({owner, sid}, :hello) end
  end

  test "a GenServer started under the via name registers and is found", %{owner: owner, sid: sid} do
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: {:via, Via, {owner, sid}})
    assert Via.whereis_name({owner, sid}) == pid

    assert {:error, {:already_started, ^pid}} =
             Agent.start_link(fn -> :ok end, name: {:via, Via, {owner, sid}})
  end
end
