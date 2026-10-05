defmodule Normandy.Agents.Turn.Supervisor.HordeTest do
  # async: false — the restart-limit tests switch off Logger's global translator filter.
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
        toolset: base.toolset,
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

  # Forwards supervisor reports (child terminated, start error, restart intensity
  # reached) to the test process, so a failing restart-limit test can show what
  # the supervisors saw. Horde's ProcessesSupervisor, which restarts sessions,
  # reports through :error_logger; Horde's outer supervisor through OTP's
  # {:supervisor, context} label. Logger drops both by default (SASL).
  defmodule SupervisorReports do
    @moduledoc false
    def log(%{msg: {:report, %{label: label, report: report}}}, %{config: %{to: to}})
        when is_list(report) do
      case {label, report[:errorContext]} do
        {{:supervisor, :progress}, _} -> :ok
        {{:supervisor, context}, _} -> forward(to, context, report)
        {{:error_logger, _}, context} when context != nil -> forward(to, context, report)
        _ -> :ok
      end
    end

    def log(_event, _config), do: :ok

    defp forward(to, context, report) do
      send(to, {:supervisor_report, report[:supervisor], context, report[:reason]})
      :ok
    end
  end

  describe "restart limit" do
    @describetag :capture_log

    setup do
      # Logger's translator drops SASL reports and rewrites the others into text,
      # so it is off while these (sync) tests run and the handler sees raw reports.
      %{filters: filters} = :logger.get_primary_config()

      translator =
        case List.keyfind(filters, :logger_translator, 0) do
          {_, translator} -> translator
          nil -> flunk("Logger has no :logger_translator primary filter to switch off")
        end

      :ok = :logger.remove_primary_filter(:logger_translator)

      # Registered before anything else can fail, so the filter always comes back.
      on_exit(fn ->
        :logger.remove_primary_filter(:logger_translator)
        :logger.add_primary_filter(:logger_translator, translator)
      end)

      handler = :"horde_reports_#{System.unique_integer([:positive])}"

      :ok =
        :logger.add_handler(handler, SupervisorReports, %{
          config: %{to: self()},
          level: :all,
          filter_default: :log
        })

      on_exit(fn -> :logger.remove_handler(handler) end)

      :ok
    end

    # The supervisor reports received so far, for a failure message. Reads the
    # mailbox without consuming it, so a passing assertion can't hide them.
    defp supervisor_reports do
      {:messages, messages} = Process.info(self(), :messages)

      reports =
        for {:supervisor_report, supervisor, context, reason} <- messages,
            do: {supervisor, context, inspect(reason, limit: 8)}

      "supervisor reports: " <> inspect(reports, pretty: true)
    end

    # An :eager session runs under restart :transient, so a kill counts as a restart.
    defp eager_sessions(sup, count) do
      reg = HReg.new()
      store = InMemory.new()
      {:ok, cat} = Catalog.start_link([])
      base = build_test_config()

      :ok =
        Catalog.put(cat, "k", %{
          toolset: base.toolset,
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

        receive do
          {:DOWN, ^ref, :process, ^pid, :killed} ->
            :ok

          {:DOWN, ^ref, :process, ^pid, other} ->
            flunk("session ended with #{inspect(other)} before the kill; #{supervisor_reports()}")
        after
          1_000 -> flunk("no :DOWN after the kill; #{supervisor_reports()}")
        end

        assert wait_until(fn ->
                 not Process.alive?(sup) or
                   match?({:ok, new} when new != pid, HReg.whereis(reg, sid))
               end),
               "the killed session was not restarted; #{supervisor_reports()}"
      end)
    end

    test "the default limit absorbs many session crashes" do
      sup = :"hsup_#{System.unique_integer([:positive])}"
      {:ok, outer} = HSup.start_link(name: sup)

      crash_each(outer, eager_sessions(sup, 6))

      assert Process.alive?(outer), supervisor_reports()
    end

    test ":max_restarts and :max_seconds set the limit" do
      Process.flag(:trap_exit, true)

      sup = :"hsup_#{System.unique_integer([:positive])}"
      {:ok, outer} = HSup.start_link(name: sup, max_restarts: 1, max_seconds: 60)

      # Not crash_each/2: a restart can fail once while the fresh registry rejects the
      # :via registration (see HReg.new/1), and the failed attempt counts too, so the
      # supervisor may give up after the first kill. That only ends it sooner; with the
      # default limit (100) two kills would not, which is what this test tells apart.
      for {_sid, _reg, pid} <- eager_sessions(sup, 2), do: Process.exit(pid, :kill)

      assert_receive {:EXIT, ^outer, _reason}, 2_000, supervisor_reports()
    end
  end

  # `start_server` performs the server's :via registration into the Horde registry,
  # which is eventually consistent: a fresh `members: :auto` cluster can transiently
  # reject the supervised start with `{{:process_not_registered_via, _}, _child}` until
  # it converges. Production tolerates this in `Turn.Session.start_with_retry`; the
  # direct `start_server` path here bypasses that, so mirror the same containment.
  # The race arrives bare or nested with the child spec, as Session's via_race?/1
  # also recognizes.
  defp start_server_with_retry(sup, opts, retries \\ 50) do
    case HSup.start_server(sup, opts) do
      {:ok, pid} ->
        pid

      {:error, reason} = err when retries > 0 ->
        if via_race?(reason),
          do: Process.sleep(10) && start_server_with_retry(sup, opts, retries - 1),
          else: flunk("start_server failed: #{inspect(err)}")

      err ->
        flunk("Horde via registration never converged: #{inspect(err)}")
    end
  end

  defp via_race?({:process_not_registered_via, _}), do: true
  defp via_race?({{:process_not_registered_via, _}, _child}), do: true
  defp via_race?(_), do: false

  defp build_test_config, do: TurnConfig.build()
end
