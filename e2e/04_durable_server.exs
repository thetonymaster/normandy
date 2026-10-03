# e2e/04_durable_server.exs — kill the session's server mid-conversation; the conversation survives.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.{BaseAgent, Turn}
alias Normandy.Behaviours.SessionRegistry.Native
alias Normandy.Behaviours.SessionStore.InMemory

S.start("04_durable_server", cap: 6)

store = InMemory.new()
reg = Native.new()
{:ok, sup} = Turn.Supervisor.start_link([])
sid = "e2e-durable-#{System.unique_integer([:positive])}"

opts = [
  session_id: sid,
  config: BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 200,
    name: "s04"
  }),
  store: {InMemory, store},
  registry: {Native, reg},
  supervisor: sup
]

say = fn n, text ->
  {:ok, r} = Turn.Session.run(opts, %{chat_message: text})
  S.turn(n, text, r.chat_message)
  r.chat_message
end

S.narrate("Two turns, then Process.exit(:kill) on the session server.")
say.(1, "My locker number is 4417. Reply 'noted'.")
say.(2, "My favourite colour is teal. Reply 'noted'.")

{:ok, old_pid} = Native.whereis(reg, sid)
Process.exit(old_pid, :kill)

new_pid =
  S.wait_for(fn ->
    case Native.whereis(reg, sid) do
      {:ok, pid} when pid != old_pid -> pid
      _ -> nil
    end
  end, 5_000, "supervisor restarts the killed session server")

S.assert!("a different server process owns the session", new_pid != old_pid, inspect({old_pid, new_pid}))

S.narrate("Three more turns on the restarted server.")
r3 = say.(3, "What is my locker number? Number only.")
r4 = say.(4, "What is my favourite colour? One word.")
r5 = say.(5, "Repeat both facts you know about me in one sentence.")

S.assert!("turn 3 recalls the locker number from before the kill", S.recalls?(r3, "4417"), r3)
S.assert!("turn 4 recalls the colour from before the kill", S.recalls?(r4, "teal"), r4)
S.assert!("turn 5 recalls both", S.recalls?(r5, "4417") and S.recalls?(r5, "teal"), r5)

{:ok, entries} = InMemory.history(store, sid)
roles = Enum.frequencies_by(entries, & &1.role)
S.narrate("Store holds #{length(entries)} entries: #{inspect(roles)}")
S.assert!("the store holds exactly 5 user and 5 assistant entries (no duplicates after restart)",
  roles == %{"user" => 5, "assistant" => 5}, inspect(roles))
S.assert!("entry ids are unique", length(Enum.uniq_by(entries, & &1.id)) == length(entries), "duplicate ids")

S.finish()
