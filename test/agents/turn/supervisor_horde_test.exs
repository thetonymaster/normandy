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
    # Horde calls take the supervisor's name; start_link's pid is Horde's outer
    # Supervisor, which would accept the child as a plain, non-Horde child.
    sup = :"hsup_#{System.unique_integer([:positive])}"
    {:ok, _} = HSup.start_link(name: sup)
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

  describe "restart limit" do
    @describetag :capture_log

    # An :eager session runs under restart :transient, so a kill counts as a restart.
    defp eager_sessions(sup, count) do
      reg = HReg.new()
      store = InMemory.new()
      {:ok, cat} = Catalog.start_link([])
      base = build_test_config()

      :ok =
        Catalog.put(cat, "k", %{
          tool_registry: base.tool_registry,
          before_hooks: [],
          after_hooks: [],
          client_builder: fn _ -> base.client end
        })

      for _ <- 1..count do
        sid = "hr-#{System.unique_integer([:positive])}"

        tmpl =
          put_in(
            ConfigTemplate.from_config(base, "k").behaviours_refs.credential,
            {Normandy.Test.StubCreds, []}
          )

        :ok = InMemory.save_config_template(store, sid, tmpl)

        pid =
          start_server_with_retry(sup,
            session_id: sid,
            store: {InMemory, store},
            registry: {HReg, reg},
            template_provider: {Catalog, cat},
            resume_policy: :eager
          )

        {sid, reg, pid}
      end
    end

    defp crash_each(sup, sessions) do
      Enum.each(sessions, fn {sid, reg, pid} ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

        wait_until(fn ->
          not Process.alive?(sup) or match?({:ok, new} when new != pid, HReg.whereis(reg, sid))
        end)
      end)
    end

    test "the default limit absorbs many session crashes" do
      sup = :"hsup_#{System.unique_integer([:positive])}"
      {:ok, outer} = HSup.start_link(name: sup)

      crash_each(outer, eager_sessions(sup, 6))

      assert Process.alive?(outer)
    end

    test ":max_restarts and :max_seconds set the limit" do
      Process.flag(:trap_exit, true)

      sup = :"hsup_#{System.unique_integer([:positive])}"
      {:ok, outer} = HSup.start_link(name: sup, max_restarts: 1, max_seconds: 60)

      crash_each(outer, eager_sessions(sup, 2))

      assert_receive {:EXIT, ^outer, _reason}, 2_000
    end
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
