defmodule Normandy.Behaviours.SessionRegistry.RedisUntrustedValueTest do
  @moduledoc """
  Registry values live in a shared Redis keyspace that other clients can write,
  so whereis/2 decodes them without creating atoms and copes with non-pids.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionRegistry.Redis

  setup do
    ns = "normandy_reg_#{System.unique_integer([:positive])}"
    owner = Redis.new(namespace: ns)

    {:ok, conn} =
      Redix.start_link(Application.get_env(:normandy, :redis_url, "redis://localhost:6379"))

    {:ok, owner: owner, conn: conn, ns: ns}
  end

  defp put_raw(conn, ns, sid, value),
    do: {:ok, "OK"} = Redix.command(conn, ["SET", "#{ns}:reg:{#{sid}}", value])

  test "a value that is not a pid is no session, and the owner survives", ctx do
    put_raw(ctx.conn, ctx.ns, "s1", :erlang.term_to_binary({:not, :a_pid}))

    assert Redis.whereis(ctx.owner, "s1") == :none
    assert Process.alive?(Process.whereis(ctx.owner.owner))
  end

  test "a value naming an unknown atom is no session and creates no atom", ctx do
    name = "normandy_never_seen_#{System.unique_integer([:positive])}"
    # External term format: SMALL_ATOM_UTF8_EXT (119), built by hand so this VM
    # never sees the atom.
    put_raw(ctx.conn, ctx.ns, "s2", <<131, 119, byte_size(name), name::binary>>)

    assert Redis.whereis(ctx.owner, "s2") == :none

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
