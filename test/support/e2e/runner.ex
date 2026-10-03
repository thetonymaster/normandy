defmodule NormandyTest.E2E.Runner do
  @moduledoc """
  Runs the live e2e scenarios in `e2e/` (see `e2e/README.md`), one OS process each.

  Lives in test/support so it never ships in the Hex package; `mix e2e` is an alias for
  `mix run e2e/run.exs` under MIX_ENV=test.
  """

  @suite_cap 120
  @default_timeout_ms 300_000
  @timeouts %{"11_distributed" => 600_000}
  @needs_postgres ["11_distributed"]
  # :peer needs a distributed origin node; hidden, so Horde's members: :auto on the
  # peers doesn't count the observing primary as a cluster member.
  @distributed ["11_distributed"]

  def discover(dir) do
    dir
    |> Path.join("[0-9][0-9]_*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      id = Path.basename(path, ".exs")
      [_num, name] = String.split(id, "_", parts: 2)
      %{id: id, name: name, path: path}
    end)
  end

  def select(all, []), do: {:ok, all}

  def select(all, names) do
    known? = fn n -> Enum.any?(all, &(&1.name == n or &1.id == n)) end

    case Enum.reject(names, known?) do
      [] ->
        {:ok, Enum.filter(all, &(&1.name in names or &1.id in names))}

      unknown ->
        {:error,
         "unknown scenario(s): #{Enum.join(unknown, ", ")}. Valid: #{Enum.map_join(all, ", ", & &1.name)}"}
    end
  end

  def parse_result(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(:missing, fn
      "E2E_RESULT " <> json ->
        %{"calls" => calls, "ms" => ms} = :json.decode(json)
        {:ok, %{calls: calls, ms: ms}}

      _ ->
        nil
    end)
  end

  def preflight(key, _scenarios, _pg) when key in [nil, ""] do
    {:error,
     "No API key: set ANTHROPIC_API_KEY or API_KEY. Every e2e scenario calls the live Anthropic API."}
  end

  def preflight(_key, scenarios, postgres_check) do
    needs_pg = Enum.filter(scenarios, &(&1.id in @needs_postgres))

    blocked =
      case needs_pg != [] and postgres_check.() do
        {:error, reason} -> Map.new(needs_pg, &{&1.id, reason})
        _ -> %{}
      end

    {:ok, %{blocked: blocked}}
  end

  def postgres_check(host \\ "localhost", port \\ 5432) do
    case :gen_tcp.connect(String.to_charlist(host), port, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error,
         "Postgres unreachable at #{host}:#{port} (#{inspect(reason)}) — run docker compose -f docker-compose.verify.yml up -d"}
    end
  end

  def command(%{id: id, path: path}) when id in @distributed,
    do: {"elixir", ["--hidden", "--name", "e2e_primary@127.0.0.1", "-S", "mix", "run", path]}

  def command(%{path: path}), do: {"mix", ["run", path]}

  def run_one(scenario, opts) do
    {exe, args} = Keyword.get_lazy(opts, :command, fn -> command(scenario) end)

    timeout_ms =
      Keyword.get(opts, :timeout_ms, Map.get(@timeouts, scenario.id, @default_timeout_ms))

    echo? = Keyword.get(opts, :echo, true)
    log = Path.join(Keyword.fetch!(opts, :report_dir), scenario.id <> ".log")
    path = System.find_executable(exe) || raise "executable #{inspect(exe)} not found on PATH"

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [{~c"MIX_ENV", ~c"test"}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    started = System.monotonic_time(:millisecond)
    {outcome, output} = collect(port, started + timeout_ms, echo?, [])
    ms = System.monotonic_time(:millisecond) - started
    File.write!(log, output)

    base = %{id: scenario.id, ms: ms, log: log, reason: nil}

    case outcome do
      :timeout ->
        _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)])

        Map.merge(base, %{
          status: :timeout,
          exit: nil,
          calls: nil,
          reason: "killed after #{timeout_ms} ms"
        })

      {:exit, status} ->
        case parse_result(output) do
          {:ok, %{calls: calls}} when status == 0 ->
            Map.merge(base, %{status: :pass, exit: 0, calls: calls})

          {:ok, %{calls: calls}} ->
            Map.merge(base, %{status: :fail, exit: status, calls: calls})

          :missing ->
            Map.merge(base, %{status: :fail, exit: status, calls: nil})
        end
    end
  end

  defp collect(port, deadline, echo?, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if echo?, do: IO.write(data)
        collect(port, deadline, echo?, [acc, data])

      {^port, {:exit_status, status}} ->
        {{:exit, status}, IO.iodata_to_binary(acc)}
    after
      remaining -> {:timeout, IO.iodata_to_binary(acc)}
    end
  end

  def summary(results) do
    rows =
      Enum.map(results, fn r ->
        calls = if is_integer(r.calls), do: Integer.to_string(r.calls), else: "?"
        exit = if is_integer(r.exit), do: Integer.to_string(r.exit), else: "-"
        secs = :erlang.float_to_binary(r.ms / 1000, decimals: 1)
        note = if r.reason, do: " #{r.reason}", else: ""

        "| #{r.id} | #{r.status |> Atom.to_string() |> String.upcase()} | #{exit} | #{calls} | #{secs} |#{note}"
      end)

    known = results |> Enum.map(& &1.calls) |> Enum.filter(&is_integer/1) |> Enum.sum()

    Enum.join(
      ["| scenario | result | exit | live calls | wall s |", "|---|---|---|---|---|"] ++
        rows ++ ["", "total live calls (known): #{known} (suite cap #{@suite_cap})"],
      "\n"
    )
  end

  # main/1 always ends in System.halt/1: it is the process exit of `mix e2e`.
  @dialyzer {:nowarn_function, main: 1}
  def main(argv) do
    all = discover("e2e")
    key = System.get_env("ANTHROPIC_API_KEY") || System.get_env("API_KEY")

    with {:ok, selected} <- select(all, argv),
         {:ok, %{blocked: blocked}} <- preflight(key, selected, &postgres_check/0) do
      dir = Path.join(["e2e", "reports", Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")])
      File.mkdir_p!(dir)
      results = run_all(selected, blocked, dir)
      table = summary(results)
      File.write!(Path.join(dir, "summary.md"), table <> "\n")
      IO.puts("\n" <> table <> "\nreports: #{dir}")
      if Enum.all?(results, &(&1.status == :pass)), do: System.halt(0), else: System.halt(1)
    else
      {:error, msg} ->
        IO.puts(:stderr, "mix e2e: " <> msg)
        System.halt(1)
    end
  end

  defp run_all(selected, blocked, dir) do
    {results, _total} =
      Enum.map_reduce(selected, 0, fn s, total ->
        cond do
          Map.has_key?(blocked, s.id) ->
            {%{
               id: s.id,
               status: :blocked,
               exit: nil,
               calls: 0,
               ms: 0,
               log: nil,
               reason: blocked[s.id]
             }, total}

          total >= @suite_cap ->
            {%{
               id: s.id,
               status: :not_run,
               exit: nil,
               calls: 0,
               ms: 0,
               log: nil,
               reason: "suite cap #{@suite_cap} reached"
             }, total}

          true ->
            r = run_one(s, report_dir: dir)
            {r, total + (r.calls || 0)}
        end
      end)

    results
  end
end
