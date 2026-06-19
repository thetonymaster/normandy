defmodule Normandy.Behaviours.SessionStore.ConcurrentAppendRedisTest do
  @moduledoc "GAP: concurrent single-session appends must not lose writes (Redis Streams, XADD)."
  use ExUnit.Case, async: false
  @moduletag :redis

  alias Normandy.Behaviours.SessionStore.Redis
  alias Normandy.Components.AgentMemory.Entry

  @n 50

  test "#{@n} concurrent appends land as #{@n} ordered stream entries" do
    store = Redis.new()
    sid = "redis-concurrent-#{System.unique_integer([:positive])}"

    results =
      1..@n
      |> Task.async_stream(
        fn i ->
          Redis.append_entry(store, sid, %Entry{turn_id: "t", role: "user", content: i})
        end,
        max_concurrency: @n,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    oks = for {:ok, id} <- results, do: id
    assert length(oks) == @n, "lost writes: #{@n - length(oks)} appends did not return {:ok, id}"

    # Flat stream: XRANGE returns every appended entry — no branching, no loss.
    {:ok, entries} = Redis.history(store, sid)
    assert length(entries) == @n, "Redis stream lost entries: #{length(entries)} of #{@n}"
    contents = entries |> Enum.map(& &1.content) |> Enum.sort()
    assert contents == Enum.to_list(1..@n), "Redis stream dropped or duplicated payloads"
  end
end
