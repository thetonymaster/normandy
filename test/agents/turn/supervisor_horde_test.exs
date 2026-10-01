defmodule Normandy.Agents.Turn.Supervisor.HordeTest do
  use ExUnit.Case, async: false
  import Normandy.Test.Eventually

  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig

  test "starts a server under Horde with a :via name and restart :temporary" do
    {:ok, sup} = HSup.start_link(name: :"hsup_#{System.unique_integer([:positive])}")
    reg = HReg.new()
    store = InMemory.new()
    {:ok, cat} = Catalog.start_link([])
    sid = "h-#{System.unique_integer([:positive])}"

    base = build_test_config()

    tmpl =
      put_in(
        ConfigTemplate.from_config(base, "k").behaviours_refs.credential,
        {Normandy.Test.StubCreds, []}
      )

    :ok = InMemory.save_config_template(store, sid, tmpl)

    :ok =
      Catalog.put(cat, "k", %{
        tool_registry: base.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _ -> base.client end
      })

    opts = [
      session_id: sid,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {HReg, reg},
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat},
      resume_policy: :lazy
    ]

    pid = start_server_with_retry(sup, opts)
    assert is_pid(pid)
    # Horde registration is eventually consistent; poll until visible.
    assert wait_until(fn -> HReg.whereis(reg, sid) == {:ok, pid} end)
  end

  # `start_server` performs the server's :via registration into the Horde registry,
  # which is eventually consistent: a fresh `members: :auto` cluster can transiently
  # reject the supervised start with `{{:process_not_registered_via, _}, _child}` until
  # it converges. Production tolerates this in `Turn.Session.start_with_retry`; the
  # direct `start_server` path here bypasses that, so mirror the same containment.
  defp start_server_with_retry(sup, opts, retries \\ 50) do
    case HSup.start_server(sup, opts) do
      {:ok, pid} ->
        pid

      {:error, {{:process_not_registered_via, _}, _child}} = err ->
        if retries > 0 do
          Process.sleep(10)
          start_server_with_retry(sup, opts, retries - 1)
        else
          flunk("Horde via registration never converged: #{inspect(err)}")
        end
    end
  end

  defp build_test_config, do: TurnConfig.build()
end
