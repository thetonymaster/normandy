defmodule Normandy.Agents.Turn.HordeInitLogTest do
  @moduledoc """
  Task 7.0e. Horde 0.10's `Horde.DynamicSupervisorImpl.init/1` logs "Starting ..." at
  `:info` before it traps exits, and its `handle_info/2` has no clause for
  `{:EXIT, pid, reason}`. A `:logger` handler runs in the logging process, and ExUnit's
  capture handler (`ExUnit.CaptureServer.log/2`, active whenever any test captures logs)
  links a `Task` to that process. When the task exits `:normal` after the impl has
  started trapping exits, the impl crashes with `FunctionClauseError` and its Horde
  supervisor (`:one_for_all`, no restarts) goes down. `test/test_helper.exs` sets the
  impl's module level to `:warning`, so no handler runs in its `init/1`.
  """
  # async: false: the test adds and removes a global :logger handler, and a concurrent
  # test's capture_log (Logger.flush/0 -> :logger.get_handler_config/0) crashes with a
  # MatchError if the handler goes between listing the ids and reading its config (OTP 27).
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup

  # Links a process to the process that logs, as ExUnit.CaptureServer.log/2's
  # Task.async does, and keeps it alive, so it is still linked when init/1 returns.
  # Acts only in the impl registered under this test's name.
  defmodule LinkingHandler do
    @moduledoc false
    def log(_event, %{config: %{sup: sup, to: to}}) do
      if Process.info(self(), :registered_name) == {:registered_name, sup} do
        linked =
          spawn_link(fn ->
            receive do
              :release -> :ok
            end
          end)

        send(to, {:linked, self(), linked})
      end

      :ok
    end
  end

  defp unique_name, do: :"horde_init_log_#{System.unique_integer([:positive])}"

  # :temporary: a crashed Horde supervisor is not restarted under the same name.
  defp start_horde(sup) do
    start_supervised!(%{
      id: sup,
      start: {HSup, :start_link, [[name: sup]]},
      type: :supervisor,
      restart: :temporary
    })
  end

  test "no log handler runs in the Horde impl's init/1" do
    sup = unique_name()
    handler = :"#{sup}_handler"

    :ok =
      :logger.add_handler(handler, LinkingHandler, %{
        config: %{sup: sup, to: self()},
        level: :all
      })

    on_exit(fn -> :logger.remove_handler(handler) end)

    outer = start_horde(sup)
    impl = Process.whereis(sup)

    # start_link returns after init/1, so a handler call made in init/1 has sent this.
    refute_received {:linked, ^impl, _linked}
    assert {:links, [^outer]} = Process.info(impl, :links)
  end

  # Pins the Horde behaviour the module level in test_helper.exs works around: when
  # this test fails, Horde handles a stray {:EXIT, pid, :normal}; drop that line.
  @tag :capture_log
  test "Horde 0.10's impl crashes on {:EXIT, pid, :normal} from a linked process" do
    sup = unique_name()
    start_horde(sup)
    impl = Process.whereis(sup)
    ref = Process.monitor(impl)
    test_pid = self()

    linked =
      spawn(fn ->
        Process.link(impl)
        send(test_pid, :linked)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :linked
    send(linked, :release)

    assert_receive {:DOWN, ^ref, :process, ^impl,
                    {:function_clause, [{Horde.DynamicSupervisorImpl, :handle_info, _, _} | _]}},
                   1_000
  end
end
