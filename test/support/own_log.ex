defmodule Normandy.Test.OwnLog do
  @moduledoc """
  `ExUnit.CaptureLog.capture_log/2` captures every process's log events, so in an
  async test it also sees what other tests log at the same moment (a crash report
  with stack frames, another test's `:boom`). A log refute that is about the code
  under test then fails on a line that test never wrote.

  `capture/2` captures the same way but keeps only the events logged by the
  calling process, each as `"<metadata>[<level>] <message>"`. Use it only when the
  code under test logs in the caller's process; a refute over a log written by
  another process belongs in an `async: false` module instead.

      log = Normandy.Test.OwnLog.capture([metadata: :all], fn -> ... end)
      refute log =~ "secret"

  `opts` are `ExUnit.CaptureLog.capture_log/2`'s, except `:format`: the capture sets its
  own format to tell events and their pids apart, so a caller's `:format` raises
  `ArgumentError`.
  """

  # Separators no log message is expected to contain: one opens an event, the
  # other ends its metadata.
  @event "\u001E"
  @meta_end "\u001F"

  @spec capture(keyword(), (-> any())) :: String.t()
  def capture(opts \\ [], fun) when is_list(opts) and is_function(fun, 0) do
    if Keyword.has_key?(opts, :format) do
      raise ArgumentError,
            "Normandy.Test.OwnLog.capture/2 sets its own :format; drop the :format option"
    end

    pid_token = "pid=" <> List.to_string(:erlang.pid_to_list(self()))

    opts
    |> Keyword.put(:format, @event <> "$metadata" <> @meta_end <> "[$level] $message\n")
    |> Keyword.update(:metadata, [:pid], &with_pid/1)
    |> ExUnit.CaptureLog.capture_log(fun)
    |> String.split(@event, trim: true)
    |> Enum.flat_map(&own_event(&1, pid_token))
    |> Enum.join()
  end

  defp with_pid(:all), do: :all
  defp with_pid(keys) when is_list(keys), do: Enum.uniq([:pid | keys])

  defp own_event(event, pid_token) do
    [metadata, rest] = String.split(event, @meta_end, parts: 2)

    if pid_token in String.split(metadata, " ", trim: true),
      do: [metadata <> rest],
      else: []
  end
end
