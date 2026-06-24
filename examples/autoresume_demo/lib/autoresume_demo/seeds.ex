defmodule AutoresumeDemo.Seeds do
  @moduledoc "Starts eager Tier-2 demo sessions through the Horde supervisor."
  require Logger

  alias AutoresumeDemo.{Agent, Topology}
  alias Normandy.Agents.Turn.Session

  @doc "Start `count` eager research sessions. Returns the list of session ids."
  @spec seed(String.t(), pos_integer()) :: [String.t()]
  def seed(topic \\ "distributed systems", count \\ 4) do
    {store_mod, store_handle} = Topology.store()
    tmpl = Agent.build_template()

    for i <- 1..count do
      sid = "research-#{:erlang.phash2({topic, i, System.unique_integer([:positive])})}"

      # Persist the eager template so the reaper can reconstruct on any node.
      :ok = store_mod.save_config_template(store_handle, sid, tmpl)

      opts = session_opts(sid)
      # Fire-and-forget: run kicks off the turn; we don't block on the result.
      spawn(fn ->
        case Session.run(opts, "Research #{topic} in #{Agent.total_steps()} steps.") do
          {:ok, _} -> :ok
          other -> Logger.warning("session #{sid} finished: #{inspect(other)}")
        end
      end)

      sid
    end
  end

  defp session_opts(sid) do
    [
      session_id: sid,
      config: Agent.base_config(),
      store: Topology.store(),
      registry: Topology.registry_handle(),
      supervisor: Topology.supervisor(),
      supervisor_mod: Normandy.Agents.Turn.Supervisor.Horde,
      template_provider: Topology.template_provider(),
      template_id: Agent.template_id(),
      resume_policy: :eager
    ]
  end
end
