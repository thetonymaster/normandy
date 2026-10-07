defmodule Normandy.Behaviours.SessionStore.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis

  use Normandy.SessionStoreContract,
    impl: Normandy.Behaviours.SessionStore.Redis,
    stored_entry_ids: {__MODULE__, :stored_entry_ids}

  use Normandy.Test.TerminalSaveCases, store: Normandy.Behaviours.SessionStore.Redis

  # Every stream in the handle's namespace; an entry's id is its `id` field, else its
  # stream id (as history/2 returns it).
  def stored_entry_ids({conn, ns}) do
    {:ok, keys} = Redix.command(conn, ["KEYS", "#{ns}:*:stream"])
    Enum.flat_map(keys, &stream_entry_ids(conn, &1))
  end

  defp stream_entry_ids(conn, key) do
    {:ok, raw} = Redix.command(conn, ["XRANGE", key, "-", "+"])
    Enum.map(raw, fn [stream_id, kv] -> entry_id(stream_id, kv) end)
  end

  defp entry_id(stream_id, kv) do
    case kv |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end) |> Map.get("id") do
      id when id in [nil, ""] -> stream_id
      id -> id
    end
  end
end
