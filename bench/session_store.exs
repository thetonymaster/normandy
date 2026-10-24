# SessionStore backends (Mnesia, Redis, Postgres; InMemory and ETS as in-process
# baselines): reading a session's history at three sizes, restoring a compacted session
# (history/2 against SessionStore.restore_history/3), then appending an entry and saving
# and loading turn state. Redis and Postgres must be reachable (bench/README.md) or left
# out with BENCH_STORES.
#
# Three Benchee runs, saved separately (session_store_history, session_store_restore,
# session_store_writes):
# the writes do not depend on the history size, and each write scenario gets its own
# store, so the entries it appends cannot slow the reads (an InMemory Agent holding
# hundreds of thousands of appended entries pays major GCs on every later call).
Code.require_file("support.exs", __DIR__)
Code.require_file("support/store_backends.exs", __DIR__)

alias Bench.StoreBackends
alias Bench.Support
alias Normandy.Behaviours.SessionStore
alias Normandy.Components.AgentMemory
alias Normandy.Components.AgentMemory.Entry

# Before any setup, so a bad BENCH_SAVE/BENCH_COMPARE fails at once.
history_opts = Support.run_opts("session_store_history")
restore_opts = Support.run_opts("session_store_restore")
writes_opts = Support.run_opts("session_store_writes")

entry = %Entry{turn_id: "t", role: "user", content: String.duplicate("x", 200)}
turn_state = %{state: :steering, iteration: 3, pending: [], answer: String.duplicate("y", 500)}
sizes = [{"10 entries", 10}, {"100 entries", 100}, {"1k entries", 1_000}]
backends = StoreBackends.selected()

new_session = fn store, kind ->
  StoreBackends.track_session(store, "bench_#{kind}_#{UUID.uuid4()}")
end

try do
  # History: per backend and size, a session pre-filled with that many entries.
  readers = Map.new(backends, &{&1, StoreBackends.session_store(&1)})

  inputs =
    Map.new(sizes, fn {name, n} ->
      {name,
       Map.new(readers, fn {backend, {mod, h} = store} ->
         filled = new_session.(store, "filled")
         for _ <- 1..n, do: {:ok, _} = mod.append_entry(h, filled, entry)
         {backend, filled}
       end)}
    end)

  for {backend, {mod, h}} <- readers, {name, n} <- sizes do
    {:ok, history} = mod.history(h, inputs[name][backend])
    Support.assert!(length(history) == n, "#{backend} history of #{name} must have #{n} entries")
  end

  Support.banner(
    "SessionStore history: #{Enum.join(backends, ", ")}",
    Enum.map(sizes, &elem(&1, 0)),
    "linear in entries; Redis and Postgres add a round trip"
  )

  history_jobs =
    Map.new(readers, fn {backend, {mod, h}} ->
      {"#{backend} history", fn input -> {:ok, _} = mod.history(h, input[backend]) end}
    end)

  Benchee.run(history_jobs, Keyword.put(history_opts, :inputs, inputs))

  # Restore: a session compacted k times, as Turn.Server stores it. Each window is
  # `window` entries, then a "compaction" snapshot holding that window; a restore needs
  # only the last snapshot and the window after it.
  window = 50

  snapshot = fn ->
    %Entry{
      id: UUID.uuid4(),
      turn_id: "t",
      role: "compaction",
      content: %{
        version: 1,
        entries:
          for(
            _ <- 1..window,
            do: %{id: UUID.uuid4(), turn_id: "t", role: "user", content: entry.content}
          )
      }
    }
  end

  compactions = [{"1 compaction", 1}, {"10 compactions", 10}, {"50 compactions", 50}]

  restore_inputs =
    Map.new(compactions, fn {name, k} ->
      {name,
       Map.new(readers, fn {backend, {mod, h} = store} ->
         compacted = new_session.(store, "compacted")

         for _ <- 1..k do
           for _ <- 1..window,
               do: {:ok, _} = mod.append_entry(h, compacted, %{entry | id: UUID.uuid4()})

           {:ok, _} = mod.append_entry(h, compacted, snapshot.())
         end

         for _ <- 1..window,
             do: {:ok, _} = mod.append_entry(h, compacted, %{entry | id: UUID.uuid4()})

         {backend, compacted}
       end)}
    end)

  for {backend, {mod, h}} <- readers, {name, _k} <- compactions do
    sid = restore_inputs[name][backend]
    {:ok, full} = mod.history(h, sid)
    {:ok, since} = SessionStore.restore_history(mod, h, sid)

    Support.assert!(
      since |> AgentMemory.from_entries() |> AgentMemory.history() ==
        full |> AgentMemory.from_entries() |> AgentMemory.history(),
      "#{backend} restore_history of #{name} must rebuild the memory history/2 does"
    )
  end

  Support.banner(
    "SessionStore restore of a compacted session: #{Enum.join(backends, ", ")}",
    Enum.map(compactions, &elem(&1, 0)),
    "history/2 linear in compactions; restore_history/3 flat (InMemory trims in-process)"
  )

  restore_jobs =
    for {backend, {mod, h}} <- readers, reduce: %{} do
      jobs ->
        Map.merge(jobs, %{
          "#{backend} history" => fn input -> {:ok, _} = mod.history(h, input[backend]) end,
          "#{backend} restore_history" => fn input ->
            {:ok, _} = SessionStore.restore_history(mod, h, input[backend])
          end
        })
    end

  Benchee.run(restore_jobs, Keyword.put(restore_opts, :inputs, restore_inputs))

  # Writes: a store of its own per backend and scenario.
  write_jobs =
    for backend <- backends, reduce: %{} do
      jobs ->
        {mod, h} = appender = StoreBackends.session_store(backend)
        appended = new_session.(appender, "append")
        {smod, sh} = stater = StoreBackends.session_store(backend)
        stated = new_session.(stater, "state")

        :ok = smod.save_turn_state(sh, stated, turn_state, false)

        Support.assert!(
          smod.load_turn_state(sh, stated) == {:ok, turn_state},
          "#{backend} load_turn_state must return the saved state"
        )

        Map.merge(jobs, %{
          "#{backend} append_entry" => fn -> {:ok, _} = mod.append_entry(h, appended, entry) end,
          "#{backend} save+load turn_state" => fn ->
            :ok = smod.save_turn_state(sh, stated, turn_state, false)
            {:ok, _} = smod.load_turn_state(sh, stated)
          end
        })
    end

  Support.banner(
    "SessionStore writes: #{Enum.join(backends, ", ")}",
    ["one 200-byte entry", "one 500-byte turn state"],
    "constant per call; Redis and Postgres add a round trip. append grows its own " <>
      "session by one entry per call"
  )

  Benchee.run(write_jobs, writes_opts)
after
  StoreBackends.cleanup!()
end
