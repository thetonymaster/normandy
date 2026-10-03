# e2e/05_approvals.exs — a delete tool gated on human approval: approved once, left to expire twice.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.{BaseAgent, Turn}
alias Normandy.Behaviours.{Config, PolicyEngine}
alias Normandy.Behaviours.SessionRegistry.Native
alias Normandy.Behaviours.SessionStore.InMemory

defmodule E2E.S05.DeleteRecord do
  use Normandy.Tools.SchemaBaseTool

  tool_schema "delete_record", "Permanently delete a customer record by id." do
    field(:record_id, :string, required: true, description: "the record id")
  end

  def execute(%__MODULE__{record_id: id}) do
    Agent.update(E2E.S05.Deleted, &[id | &1])
    {:ok, "deleted #{id}"}
  end
end

S.start("05_approvals", cap: 6)
{:ok, _} = Agent.start_link(fn -> [] end, name: E2E.S05.Deleted)

store = InMemory.new()
reg = Native.new()
{:ok, sup} = Turn.Supervisor.start_link([])
parent = self()

config =
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 300,
    name: "s05",
    behaviours: %Config{
      policy: {PolicyEngine.Ruleset,
               rules: [%{match: "delete_record", action: :require_approval, rule_id: "R-deletes-need-approval"}],
               default_action: :allow}
    }
  })
  |> BaseAgent.register_tool(struct!(E2E.S05.DeleteRecord))

session = fn sid, mode ->
  [
    session_id: sid,
    config: config,
    store: {InMemory, store},
    registry: {Native, reg},
    supervisor: sup,
    approval_timeout_ms: 1_500,
    on_approval_timeout: mode,
    subscriber: fn name, meta -> send(parent, {:event, sid, name, meta}) end
  ]
end

run_async = fn opts, text -> spawn(fn -> send(parent, {:result, opts[:session_id], Turn.Session.run(opts, %{chat_message: text})}) end) end

await_park = fn sid ->
  receive do
    {:event, ^sid, :awaiting_approval, meta} -> meta
  after
    60_000 -> S.assert!("#{sid} parks for approval", false, "no :awaiting_approval within 60 s")
  end
end

await_result = fn sid ->
  receive do
    {:result, ^sid, result} -> result
  after
    60_000 -> S.assert!("#{sid} finishes", false, "no result within 60 s")
  end
end

parked_ids = fn sid ->
  {:ok, %Turn.State{parked_calls: parked}} = InMemory.load_turn_state(store, sid)
  Enum.map(parked, & &1.id)
end

sid = "e2e-approve-#{System.unique_integer([:positive])}"
opts = session.(sid, :continue)

S.narrate("Turn 1: the model asks to delete R-100; a human approves.")
run_async.(opts, "Delete customer record R-100.")
meta = await_park.(sid)
S.assert!("the delete call parks for approval", meta.parked == 1, inspect(meta))
ids = parked_ids.(sid)
:ok = Turn.Session.approve(opts, Map.new(ids, &{&1, :approve}))
{:ok, r1} = await_result.(sid)
S.turn(1, "Delete customer record R-100.", r1.chat_message)
S.assert!("the approved delete ran", Agent.get(E2E.S05.Deleted, & &1) == ["R-100"], inspect(Agent.get(E2E.S05.Deleted, & &1)))

S.narrate("Turn 2: the model asks to delete R-200; nobody answers within 1.5 s (:continue).")
run_async.(opts, "Now delete customer record R-200.")
await_park.(sid)

receive do
  {:event, ^sid, :approval_expired, m} -> S.assert!("the approval expires in :continue mode", m.mode == :continue and m.expired == 1, inspect(m))
after
  10_000 -> S.assert!("the approval expires", false, "no :approval_expired within 10 s")
end

{:ok, r2} = await_result.(sid)
S.turn(2, "Now delete customer record R-200.", r2.chat_message)
S.assert!("the expired delete never ran", Agent.get(E2E.S05.Deleted, & &1) == ["R-100"], inspect(Agent.get(E2E.S05.Deleted, & &1)))
S.assert!("expiry telemetry fired", S.events([:normandy, :turn, :approval, :expired]) != [], "no telemetry")

S.narrate("A second session with on_approval_timeout: :fail.")
fsid = "e2e-approve-fail-#{System.unique_integer([:positive])}"
fopts = session.(fsid, :fail)
run_async.(fopts, "Delete customer record R-300.")
await_park.(fsid)
fids = parked_ids.(fsid)
result = await_result.(fsid)
S.narrate("Result: #{inspect(result)}")
S.assert!(":fail mode returns approval_timeout with the parked ids", result == {:error, {:approval_timeout, fids}}, inspect(result))
S.assert!("still only R-100 deleted", Agent.get(E2E.S05.Deleted, & &1) == ["R-100"], "")

S.finish()
