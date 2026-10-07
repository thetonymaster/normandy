defmodule Normandy.Behaviours.SessionStore.RedisPipelineErrorTest do
  @moduledoc """
  A Redis error returned inside a pipeline's results (Redix reports it in-band, in
  `{:ok, results}`) fails the write instead of being dropped.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis

  # The in-flight index key holds a string, so SADD and SREM answer WRONGTYPE.
  defp broken_index do
    {conn, ns} = h = Redis.new()
    {:ok, "OK"} = Redix.command(conn, ["SET", "#{ns}:inflight", "not-a-set"])
    {h, conn, ns}
  end

  test "save_turn_state/4 returns the index command's in-band error, in flight or not" do
    {h, conn, ns} = broken_index()

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} =
             Redis.save_turn_state(h, "s1", :steering, true)

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} =
             Redis.save_turn_state(h, "s1", :stopped, false)

    {:ok, _} = Redix.command(conn, ["DEL", "#{ns}:inflight", "#{ns}:{s1}:meta"])
  end

  test "delete_session returns the index command's in-band error" do
    {h, conn, ns} = broken_index()

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} = Redis.delete_session(h, "s1")

    {:ok, _} = Redix.command(conn, ["DEL", "#{ns}:inflight"])
  end
end
