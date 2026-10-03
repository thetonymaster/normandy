# e2e/14_memory.exs — persistent memory across sessions, isolated by namespace.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Behaviours.MemoryStore.InMemory
alias Normandy.Tools.Memory

S.start("14_memory", cap: 18)
handle = InMemory.new()

# A new agent per session: fresh conversation memory, same long-term store.
session = fn namespace ->
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 600,
    name: "s14",
    max_tool_iterations: 6,
    tool_context: %{memory_namespace: namespace}
  })
  |> BaseAgent.register_tool(Memory.new(store: {InMemory, handle}))
end

ask = fn agent, n, text ->
  {_agent, r} = BaseAgent.run(agent, %{chat_message: text})
  S.turn(n, text, r.chat_message)
  r.chat_message
end

stored_text = fn namespace ->
  {:ok, entries} = InMemory.list(handle, namespace, "/memories")

  text =
    Enum.map_join(entries, "\n", fn %{path: p} ->
      {:ok, %{content: c}} = InMemory.get(handle, namespace, p)
      c
    end)

  {entries, text}
end

S.narrate(
  "Session 1 (alice) stores a fact; session 2 (alice) recalls it; session 3 (bob) must not."
)

ask.(
  session.("acme/alice"),
  1,
  "Please remember for our future conversations: my locker code is KESTREL-42."
)

{entries, stored} = stored_text.("acme/alice")

S.assert!(
  "session 1 wrote the fact into alice's memory",
  S.recalls?(stored, "KESTREL-42"),
  inspect(entries)
)

r2 = ask.(session.("acme/alice"), 2, "What is my locker code?")
S.assert!("session 2 (same namespace) recalls the fact", S.recalls?(r2, "KESTREL-42"), r2)

r3 = ask.(session.("acme/bob"), 3, "What is my locker code?")
S.assert!("session 3 (another namespace) does not see it", not S.recalls?(r3, "KESTREL-42"), r3)

{bob, bob_text} = stored_text.("acme/bob")

S.assert!(
  "bob's namespace holds none of alice's facts",
  not S.recalls?(bob_text, "KESTREL-42"),
  inspect(bob)
)

stops = S.events([:normandy, :memory, :command, :stop])
S.assert!("the model used the memory tool", stops != [], "no memory command events")

S.assert!(
  "no memory command hit a backend error",
  not Enum.any?(stops, fn {_m, meta} -> Map.get(meta, :error_type) == :backend end),
  inspect(stops)
)

S.finish()
