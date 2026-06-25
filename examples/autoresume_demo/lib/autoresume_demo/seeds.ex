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

      # `Session.run`'s first-start rehydrate path re-derives the template via
      # `ConfigTemplate.from_config/2`, which hardcodes `resume_policy: :lazy` and
      # clobbers the queryable `resume_policy` column we just set to `eager`. That
      # would hide the session from `SessionStore.list_resumable/1`, so neither the
      # ResumeReaper (eager handoff) nor the demo's "find a running session" probe
      # could see it. Re-assert the eager template AFTER the server has started so
      # the eager policy persists. (The thin reaper restart never re-saves, so this
      # one fix-up survives a handoff.)
      :ok = reassert_eager(store_mod, store_handle, sid, tmpl)

      sid
    end
  end

  # Wait until the server is registered (which means `Session.run` has passed the
  # clobbering rehydrate), then re-save the eager template to flip the policy back.
  defp reassert_eager(store_mod, store_handle, sid, tmpl, tries \\ 50) do
    {reg_mod, reg_handle} = Topology.registry_handle()

    cond do
      match?({:ok, _}, reg_mod.whereis(reg_handle, sid)) ->
        store_mod.save_config_template(store_handle, sid, tmpl)

      tries > 0 ->
        Process.sleep(20)
        reassert_eager(store_mod, store_handle, sid, tmpl, tries - 1)

      true ->
        # Server never registered in time; still re-assert so the eager policy is
        # correct for the reaper even if this session is slow to come up.
        store_mod.save_config_template(store_handle, sid, tmpl)
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
