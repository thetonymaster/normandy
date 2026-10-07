defmodule Normandy.Behaviours.SessionStore.RedisPipelineErrorTest do
  @moduledoc """
  A Redis error returned inside a pipeline's results (Redix reports it in-band, in
  `{:ok, results}`) fails the write instead of being dropped.
  """
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis

  test "save_config_template returns a command's in-band error" do
    {conn, ns} = h = Redis.new()
    # The eager set's key holds a string, so SADD answers WRONGTYPE.
    {:ok, "OK"} = Redix.command(conn, ["SET", "#{ns}:resumable", "not-a-set"])

    assert {:error, %Redix.Error{message: "WRONGTYPE" <> _}} =
             Redis.save_config_template(h, "s1", %{template_id: "k", resume_policy: :eager})

    {:ok, _} = Redix.command(conn, ["DEL", "#{ns}:resumable", "#{ns}:{s1}:meta"])
  end
end
