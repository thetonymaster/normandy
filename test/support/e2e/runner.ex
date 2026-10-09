defmodule NormandyTest.E2E.Runner do
  @moduledoc """
  Runs the live e2e scenarios in `e2e/` (see `e2e/README.md`), one OS process each.

  Lives in test/support so it never ships in the Hex package; `mix e2e` is an alias for
  `mix run e2e/run.exs` under MIX_ENV=test.
  """

  alias NormandyTest.E2E.Prices

  @suite_cap 150
  @default_timeout_ms 300_000
  @timeouts %{
    "11_distributed" => 600_000,
    "15_preserved_thinking" => 1_200_000,
    "16_mcp_pause" => 600_000
  }
  @needs_postgres ["11_distributed"]
  # :peer needs a distributed origin node; hidden, so Horde's members: :auto on the
  # peers doesn't count the observing primary as a cluster member.
  @distributed ["11_distributed"]
  # Assumed tokens per call for `estimate/1` (input, output); every scenario at its cap.
  @est_tokens %{"15_preserved_thinking" => {8_000, 2_000}, "16_mcp_pause" => {30_000, 1_000}}
  @default_est_tokens {6_000, 400}

  def discover(dir) do
    dir
    |> Path.join("[0-9][0-9]_*.exs")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      id = Path.basename(path, ".exs")
      [_num, name] = String.split(id, "_", parts: 2)
      %{id: id, name: name, path: path, cap: declared_cap(path)}
    end)
  end

  # The cap the scenario passes to E2E.Support.start/2; each scenario halts past it.
  defp declared_cap(path) do
    case Regex.run(~r/S\.start\("[^"]+", cap: (\d+)\)/, File.read!(path)) do
      [_, cap] -> String.to_integer(cap)
      nil -> nil
    end
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
      "E2E_RESULT " <> json -> decode_result(json)
      _ -> nil
    end)
  end

  defp decode_result(json) do
    case Jason.decode(json) do
      {:ok, %{"calls" => calls, "ms" => ms} = result} when is_integer(calls) and is_integer(ms) ->
        case decode_usage(Map.get(result, "usage")) do
          {:ok, usage} -> {:ok, %{calls: calls, ms: ms, usage: usage}}
          :error -> {:error, "malformed E2E_RESULT usage: #{String.slice(json, 0, 200)}"}
        end

      _ ->
        {:error, "malformed E2E_RESULT line: #{String.slice(json, 0, 200)}"}
    end
  end

  defp decode_usage(nil), do: {:ok, nil}

  defp decode_usage(%{
         "input" => i,
         "output" => o,
         "cache_read" => r,
         "cache_write" => w,
         "cost_usd" => c
       })
       when is_integer(i) and is_integer(o) and is_integer(r) and is_integer(w) and
              (is_number(c) or is_nil(c)),
       do: {:ok, %{input: i, output: o, cache_read: r, cache_write: w, cost: c && c / 1}}

  defp decode_usage(_other), do: :error

  def preflight(key, _scenarios, _pg) when key in [nil, ""] do
    {:error,
     "No API key: set ANTHROPIC_API_KEY or API_KEY. Every e2e scenario calls the live Anthropic API."}
  end

  def preflight(_key, scenarios, postgres_check) do
    with :ok <- check_caps(scenarios) do
      needs_pg = Enum.filter(scenarios, &(&1.id in @needs_postgres))

      blocked =
        case needs_pg != [] and postgres_check.() do
          {:error, reason} -> Map.new(needs_pg, &{&1.id, reason})
          _ -> %{}
        end

      {:ok, %{blocked: blocked}}
    end
  end

  # Each scenario halts past its own cap, so the caps' sum bounds a run's spend
  # before any request is made.
  defp check_caps(scenarios) do
    case Enum.filter(scenarios, &is_nil(&1.cap)) do
      [] ->
        total = scenarios |> Enum.map(& &1.cap) |> Enum.sum()

        if total <= @suite_cap,
          do: :ok,
          else:
            {:error,
             "the selected scenarios' live-call caps sum to #{total}, over the suite cap #{@suite_cap}"}

      uncapped ->
        {:error,
         "no live-call cap declared (S.start(id, cap: n)) in: #{Enum.map_join(uncapped, ", ", & &1.id)}"}
    end
  end

  # Reachability of the Postgres the test config points at (POSTGRES_HOST, default localhost).
  def postgres_check do
    repo = Application.get_env(:normandy, Normandy.TestRepo, [])
    postgres_check(Keyword.get(repo, :hostname, "localhost"), Keyword.get(repo, :port, 5432))
  end

  def postgres_check(host, port) do
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

    base = %{id: scenario.id, ms: ms, log: log, reason: nil, os_pid: os_pid}

    case outcome do
      :timeout ->
        _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
        await_exit(port, os_pid)

        Map.merge(base, %{
          status: :fail,
          exit: nil,
          calls: nil,
          usage: nil,
          reason: "timeout: killed after #{timeout_ms} ms"
        })

      {:exit, status} ->
        case parse_result(output) do
          {:ok, %{calls: calls, usage: usage}} when status == 0 ->
            Map.merge(base, %{status: :pass, exit: 0, calls: calls, usage: usage})

          {:ok, %{calls: calls, usage: usage}} ->
            Map.merge(base, %{status: :fail, exit: status, calls: calls, usage: usage})

          :missing ->
            Map.merge(base, %{status: :fail, exit: status, calls: nil, usage: nil})

          {:error, reason} ->
            Map.merge(base, %{status: :fail, exit: status, calls: nil, usage: nil, reason: reason})
        end
    end
  end

  # The port reports the exit once the OS has reaped the killed process.
  defp await_exit(port, os_pid) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      10_000 -> raise "scenario os pid #{os_pid} survived kill -9 for 10 s"
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
        cost = if r.usage && r.usage.cost, do: Prices.dollars(r.usage.cost), else: "?"
        note = if r.reason, do: " #{r.reason}", else: ""

        "| #{r.id} | #{r.status |> Atom.to_string() |> String.upcase()} | #{exit} | #{calls} | " <>
          "#{secs} | #{cost} |#{note}"
      end)

    known = results |> Enum.map(& &1.calls) |> Enum.filter(&is_integer/1) |> Enum.sum()
    usage = results |> Enum.map(& &1.usage) |> Enum.reject(&is_nil/1) |> Prices.sum()

    Enum.join(
      ["| scenario | result | exit | live calls | wall s | est $ |", "|---|---|---|---|---|---|"] ++
        rows ++
        [
          "",
          "total live calls (known): #{known} (suite cap #{@suite_cap})",
          Prices.format(usage, "usage (known)")
        ],
      "\n"
    )
  end

  @doc """
  A spend estimate for `scenarios` before a run: every scenario at its live-call cap, with
  the assumed tokens per call in `@est_tokens`. "Upper" prices every input token as a
  cache write. A scenario that contains `S.model(:opus)` is priced as Opus 5.5.
  """
  def estimate(scenarios) do
    rows =
      Enum.map(scenarios, fn s ->
        model =
          if File.read!(s.path) =~ "S.model(:opus)",
            do: "claude-opus-5-5",
            else: "claude-haiku-4-5"

        {input, output} = Map.get(@est_tokens, s.id, @default_est_tokens)
        p = Prices.price!(model)
        expected = s.cap * (input * p.input + output * p.output) / 1_000_000
        upper = s.cap * (input * p.cache_write + output * p.output) / 1_000_000

        {"| #{s.id} | #{model} | #{s.cap} | #{input}+#{output} | #{Prices.dollars(expected)} | " <>
           "#{Prices.dollars(upper)} |", expected, upper}
      end)

    expected = rows |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    upper = rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    Enum.join(
      [
        "| scenario | model | cap | tokens/call in+out | est $ | upper $ |",
        "|---|---|---|---|---|---|"
      ] ++
        Enum.map(rows, &elem(&1, 0)) ++
        [
          "",
          "estimate: $#{Prices.dollars(expected)} expected, $#{Prices.dollars(upper)} upper bound " <>
            "(every scenario at its cap)"
        ],
      "\n"
    )
  end

  # main/1 always ends in System.halt/1: it is the process exit of `mix e2e`.
  @dialyzer {:nowarn_function, main: 1}
  def main(["--estimate" | names]) do
    all = discover("e2e")

    with {:ok, selected} <- select(all, names),
         :ok <- check_caps(selected) do
      IO.puts(estimate(selected))
      System.halt(0)
    else
      {:error, msg} ->
        IO.puts(:stderr, "mix e2e --estimate: " <> msg)
        System.halt(1)
    end
  end

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
    Enum.map(selected, fn s ->
      case Map.fetch(blocked, s.id) do
        {:ok, reason} ->
          %{
            id: s.id,
            status: :blocked,
            exit: nil,
            calls: 0,
            ms: 0,
            log: nil,
            reason: reason,
            usage: nil
          }

        :error ->
          run_one(s, report_dir: dir)
      end
    end)
  end
end
