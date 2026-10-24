defmodule Normandy.Test.OwnLogTest do
  use ExUnit.Case, async: true

  require Logger

  alias Normandy.Test.OwnLog

  # Another process logs a crash report with a stack frame inside the capture
  # window; the capture returns only after that process is gone.
  defp log_mine_and_crash_another do
    # Metadata built apart from the call, as lib/ does (no Logger config keys here).
    metadata = [marker: :own]
    Logger.warning("mine-#{inspect(self())}", metadata)
    {:ok, pid} = Task.start(fn -> raise "other-process" end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  test "capture_log sees another process's crash report (the flake's mechanism)" do
    log = ExUnit.CaptureLog.capture_log(&log_mine_and_crash_another/0)

    assert log =~ "mine-"
    assert log =~ "other-process"
    assert log =~ ~r/support_own_log_test\.exs:\d+/
  end

  test "capture/2 keeps only the caller's events, with their metadata" do
    log = OwnLog.capture([metadata: :all], &log_mine_and_crash_another/0)

    assert log =~ "[warning] mine-#{inspect(self())}"
    assert log =~ "marker=own"
    refute log =~ "other-process"
    refute log =~ ~r/\.exs?:\d+/
  end

  test "capture/2 adds :pid to a metadata list and keeps the caller's keys" do
    log = OwnLog.capture([metadata: [:marker]], &log_mine_and_crash_another/0)

    assert log =~ "marker=own"
    assert log =~ "mine-"
    refute log =~ "other-process"
  end

  # 6.6a review: the capture's own format would silently replace a caller's.
  test "capture/2 refuses a caller's :format" do
    assert_raise ArgumentError, ~r/sets its own :format/, fn ->
      OwnLog.capture([format: "$message"], fn -> :ok end)
    end
  end
end
