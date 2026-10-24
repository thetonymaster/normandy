# SessionStore backends (Mnesia, Redis, Postgres; InMemory and ETS as in-process
# baselines): appending an entry, reading a session's history, and saving and loading
# its turn state. Redis and Postgres must be reachable (bench/README.md) or left out
# with BENCH_STORES.
Code.require_file("support.exs", __DIR__)
Code.require_file("support/store_backends.exs", __DIR__)

alias Bench.StoreBackends
alias Bench.Support
alias Normandy.Components.AgentMemory.Entry

entry = %Entry{turn_id: "t", role: "user", content: String.duplicate("x", 200)}
turn_state = %{state: :steering, iteration: 3, pending: [], answer: String.duplicate("y", 500)}
sizes = [{"10 entries", 10}, {"100 entries", 100}, {"1k entries", 1_000}]
backends = StoreBackends.selected()

# Per backend and size: a session pre-filled with that many entries (read by history)
# and an empty one (appended to, and holding the turn state).
prepare = fn {mod, h} = store, n ->
  filled = StoreBackends.track_session(store, "bench_filled_#{UUID.uuid4()}")
  for _ <- 1..n, do: {:ok, _} = mod.append_entry(h, filled, entry)
  appended = StoreBackends.track_session(store, "bench_append_#{UUID.uuid4()}")
  %{filled: filled, appended: appended}
end

try do
  stores = Map.new(backends, &{&1, StoreBackends.session_store(&1)})

  inputs =
    Map.new(sizes, fn {name, n} ->
      {name, Map.new(stores, fn {backend, store} -> {backend, prepare.(store, n)} end)}
    end)

  for {backend, {mod, h}} <- stores, {name, n} <- sizes do
    ids = inputs[name][backend]
    {:ok, history} = mod.history(h, ids.filled)
    Support.assert!(length(history) == n, "#{backend} history of #{name} must have #{n} entries")
    :ok = mod.save_turn_state(h, ids.appended, turn_state, false)

    Support.assert!(
      mod.load_turn_state(h, ids.appended) == {:ok, turn_state},
      "#{backend} load_turn_state must return the saved state"
    )
  end

  Support.banner(
    "SessionStore backends: #{Enum.join(backends, ", ")}",
    Enum.map(sizes, &elem(&1, 0)),
    "append and turn state constant per call; history linear in entries; Redis and " <>
      "Postgres add a round trip. append grows its own session by one entry per call"
  )

  jobs =
    for {backend, {mod, h}} <- stores, reduce: %{} do
      jobs ->
        Map.merge(jobs, %{
          "#{backend} append_entry" => fn input ->
            {:ok, _} = mod.append_entry(h, input[backend].appended, entry)
          end,
          "#{backend} history" => fn input -> {:ok, _} = mod.history(h, input[backend].filled) end,
          "#{backend} save+load turn_state" => fn input ->
            :ok = mod.save_turn_state(h, input[backend].appended, turn_state, false)
            {:ok, _} = mod.load_turn_state(h, input[backend].appended)
          end
        })
    end

  Benchee.run(jobs, Support.run_opts("session_store", inputs: inputs))
after
  StoreBackends.cleanup!()
end
