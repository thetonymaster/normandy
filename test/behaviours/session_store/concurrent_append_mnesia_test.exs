defmodule Normandy.Behaviours.SessionStore.ConcurrentAppendMnesiaTest do
  @moduledoc "GAP: concurrent single-session appends must not lose writes (Mnesia, transactional)."
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Mnesia
  alias Normandy.Components.AgentMemory.Entry

  # Pristine-schema setup — required so this test works correctly inside the full
  # `--include distributed` combo. Without it, if a prior distributed test calls
  # `:net_kernel.start/1` (renaming the node from `:nonode@nohost` to e.g.
  # `primary@127.0.0.1`), the Mnesia schema still records `:nonode@nohost` as a
  # db_node. Subsequent `create_table` calls then block in a schema_transaction
  # waiting to coordinate with the phantom `:nonode@nohost`. Fix: reset Mnesia so
  # the schema reflects the current node name. Copied from mnesia_test.exs.
  setup do
    :mnesia.stop()
    :mnesia.delete_schema([node()])
    :ok = :mnesia.start()

    on_exit(fn -> :mnesia.stop() end)
  end

  @n 50

  test "#{@n} concurrent appends to one session yield #{@n} distinct persisted ids" do
    store = Mnesia.new()
    sid = "mnesia-concurrent"

    results =
      1..@n
      |> Task.async_stream(
        fn i ->
          Mnesia.append_entry(store, sid, %Entry{turn_id: "t", role: "user", content: i})
        end,
        max_concurrency: @n,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    oks = for {:ok, id} <- results, do: id
    assert length(oks) == @n, "lost writes: #{@n - length(oks)} appends did not return {:ok, id}"
    assert length(Enum.uniq(oks)) == @n, "duplicate ids returned — id generation is not unique"

    # append_entry reads-then-writes the session head inside one :mnesia.transaction,
    # which serializes concurrent appends to a single session — so the active chain is
    # always linear and complete (no branching). (Chain-completeness is also covered by
    # the shared SessionStoreContract; asserted here for the concurrent path explicitly.)
    {:ok, chain} = Mnesia.history(store, sid)

    assert length(chain) == @n,
           "active chain not linear/complete under concurrency: #{length(chain)} != #{@n}"
  end
end
