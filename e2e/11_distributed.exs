# e2e/11_distributed.exs — the node owning a session dies mid-turn; another node resumes it eagerly.
# Needs Postgres (docker-compose.verify.yml + MIX_ENV=test mix ecto.setup) and a distributed
# primary: `mix e2e distributed` starts it with --hidden --name e2e_primary@127.0.0.1.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias NormandyTest.E2E.Distributed, as: D
alias Normandy.Agents.Turn
alias Normandy.Behaviours.SessionStore.Postgres, as: PG

S.start("11_distributed", cap: 6)
S.assert!("the primary node is distributed", Node.alive?(), "start with: MIX_ENV=test elixir --hidden --name e2e_primary@127.0.0.1 -S mix run e2e/11_distributed.exs")

main = self()

sink =
  spawn_link(fn ->
    loop = fn loop ->
      receive do
        {:remote_call, m} -> S.count_remote_call(m)
        other -> send(main, other)
      end

      loop.(loop)
    end

    loop.(loop)
  end)

true = Process.register(sink, D.sink_name())

repo_opts = Application.fetch_env!(:normandy, Normandy.TestRepo)
{:ok, _} = Normandy.TestRepo.start_link(pool: DBConnection.ConnectionPool, pool_size: 2)
Ecto.Migrator.run(Normandy.TestRepo, Path.expand("priv/test_repo/migrations"), :up, all: true, log: false)

S.narrate("Starting peers A and B (Horde members); the primary only observes.")
u = System.unique_integer([:positive])
peers = Map.new([:a, :b], fn k -> {pid, node} = Normandy.ClusterCase.start_peer(:"e2e_#{k}_#{u}"); {node, pid} end)
nodes = Map.keys(peers)

for node <- nodes do
  :ok = :erpc.call(node, D, :boot, [Application.get_all_env(:normandy), Application.get_all_env(:claudio), repo_opts, node()], 30_000)
end

[peer_a, peer_b] = nodes
true = :erpc.call(peer_a, Node, :connect, [peer_b])

S.wait_for(fn -> Enum.all?(nodes, &(:erpc.call(&1, D, :members, []) == 2)) end, 15_000, "both peers see a 2-member Horde cluster")
S.wait_for(fn -> Enum.all?(nodes, &:erpc.call(&1, D, :registry_ready?, [])) end, 15_000, "both peers' registries accept registrations")

[a, _b] = nodes
sid = "e2e-dist-#{u}"
:ok = :erpc.call(a, D, :prepare, [sid])

turn = fn node, n, text ->
  r = :erpc.call(node, D, :run_turn, [sid, text], 120_000)
  S.turn(n, "#{text}   (via #{node})", r)
  r
end

turn.(a, 1, "My badge id is ORCA-19. Reply 'noted'.")
turn.(a, 2, "My team is called Kestrel. Reply 'noted'.")

S.narrate("Turn 3 asks for a refund; the gated tool parks the turn awaiting approval.")
spawn(fn ->
  # This caller's node is stopped below, so its call ends in :noconnection by design.
  try do
    r = :erpc.call(a, D, :run_turn, [sid, "Issue a refund for order A-77 using the issue_refund tool."], :infinity)
    send(main, {:turn3_caller, :returned, r})
  catch
    kind, reason -> send(main, {:turn3_caller, kind, reason})
  end
end)

receive do
  {:session_event, _node, :awaiting_approval, meta} -> S.assert!("turn 3 parked for approval", meta.parked == 1, inspect(meta))
after
  60_000 -> S.assert!("turn 3 parked for approval", false, "no :awaiting_approval within 60 s")
end

{:ok, owner_pid} = :erpc.call(a, D, :owner, [sid])
owner = node(owner_pid)
[survivor] = nodes -- [owner]
{:ok, %Turn.State{parked_calls: parked}} = PG.load_turn_state(Normandy.TestRepo, sid)
ids = Enum.map(parked, & &1.id)
{:ok, entries_at_park} = PG.history(Normandy.TestRepo, sid)

S.narrate("Stopping the owning node #{owner}; #{survivor} should take the session over.")
:ok = :peer.stop(Map.fetch!(peers, owner))

new_pid =
  S.wait_for(fn ->
    case :erpc.call(survivor, D, :owner, [sid]) do
      {:ok, pid} when node(pid) == survivor -> pid
      _ -> nil
    end
  end, 30_000, "the reaper restarts the session on the surviving node")

receive do
  # Its error depends on placement: :noconnection if the server ran on the stopped node
  # that also ran the call, :nodedown from gen_statem if the server was elsewhere.
  {:turn3_caller, kind, reason} ->
    S.assert!("turn 3's original caller got no reply (expected; the turn lives on in the store)",
      kind != :returned, inspect({kind, reason}))
after
  15_000 -> S.assert!("turn 3's caller saw its node go away", false, "no result within 15 s")
end

S.assert!("the revived server is alive on #{survivor}", :erpc.call(survivor, Process, :alive?, [new_pid]), inspect(new_pid))

:ok = :erpc.call(survivor, D, :approve, [sid, Map.new(ids, &{&1, :approve})])

receive do
  {:tool_ran, node, order} -> S.assert!("the approved refund ran on the survivor", node == survivor and order == "A-77", inspect({node, order}))
after
  60_000 -> S.assert!("the approved refund ran", false, "no tool run within 60 s")
end

S.wait_for(fn ->
  {:ok, es} = PG.history(Normandy.TestRepo, sid)
  length(es) >= length(entries_at_park) + 2 and List.last(es).role == "assistant"
end, 60_000, "the resumed turn 3 finished on the survivor")

r4 = turn.(survivor, 4, "What is my badge id and my team name?")
S.assert!("turn 4 recalls turn 1 across the handoff", S.recalls?(r4, "ORCA-19"), r4)
S.assert!("turn 4 recalls turn 2 across the handoff", S.recalls?(r4, "Kestrel"), r4)

{:ok, final_pid} = :erpc.call(survivor, D, :owner, [sid])
S.assert!("one live server for the session, on the survivor", node(final_pid) == survivor and owner not in Node.list(), inspect({final_pid, Node.list()}))

:peer.stop(Map.fetch!(peers, survivor))
S.finish()
