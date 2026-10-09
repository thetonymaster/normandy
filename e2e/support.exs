# e2e/support.exs — shared by every e2e/NN_*.exs scenario. Loaded with Code.require_file.
Code.require_file("otel_bridge.exs", __DIR__)

defmodule E2E.Support do
  @moduledoc false

  @model "claude-haiku-4-5-20251001"
  @probe_events [
    [:normandy, :agent, :compaction],
    [:normandy, :agent, :guardrail, :violation],
    [:normandy, :agent, :llm_call, :stop],
    [:normandy, :turn, :approval, :expired],
    [:normandy, :memory, :command, :stop]
  ]

  # Scenario 15 (AX-7): preserved thinking is checked on Opus 5.5, never on Haiku 4.5.
  @opus "claude-opus-5-5"

  alias NormandyTest.E2E.Prices

  def model, do: @model
  def model(:opus), do: @opus

  def start(id, cap: cap) do
    {:ok, _} =
      Agent.start_link(
        fn -> %{id: id, cap: cap, calls: 0, usages: [], priced: [], events: %{}, t0: System.monotonic_time(:millisecond)} end,
        name: __MODULE__
      )

    # Lifecycle [info] logs would bury the narrated transcript; warnings and errors stay.
    Logger.configure(level: :warning)
    :ok = :telemetry.attach("e2e-claudio-calls", [:claudio, :messages, :create, :stop], &__MODULE__.on_call/4, nil)
    # A streamed request reports its tokens when the stream ends, not on create's stop.
    :ok =
      :telemetry.attach(
        "e2e-claudio-stream-usage",
        [:claudio, :messages, :stream, :stop],
        &__MODULE__.on_stream_usage/4,
        nil
      )

    :ok = :telemetry.attach_many("e2e-probes", @probe_events, &__MODULE__.on_event/4, nil)
    IO.puts("\n=== #{id} (live-call cap #{cap}) ===")
    if otel?(), do: E2E.OtelBridge.setup(id)
    :ok
  end

  # NORMANDY_E2E_OTLP=1 exports Normandy's spans to e2e/otel's Tempo (see e2e/otel_bridge.exs).
  defp otel?, do: System.get_env("NORMANDY_E2E_OTLP") not in [nil, "", "0", "false"]

  defp otel_report, do: if(otel?(), do: E2E.OtelBridge.report())

  @doc false
  def on_call(_event, measurements, meta, _config),
    do: count_remote_call(measurements, Map.get(meta, :model))

  @doc false
  def on_stream_usage(_event, measurements, meta, _config) do
    Agent.update(__MODULE__, fn s -> %{s | priced: s.priced ++ [{Map.get(meta, :model), measurements}]} end)
  end

  @doc false
  def on_event(event, measurements, metadata, _config) do
    Agent.update(__MODULE__, fn s ->
      %{s | events: Map.update(s.events, event, [{measurements, metadata}], &(&1 ++ [{measurements, metadata}]))}
    end)
  end

  @doc "Count one real Messages API request; halts the scenario when the cap is exceeded."
  def count_remote_call(measurements, model \\ @model) do
    {n, cap} =
      Agent.get_and_update(__MODULE__, fn s ->
        s = %{
          s
          | calls: s.calls + 1,
            usages: s.usages ++ [measurements],
            priced: s.priced ++ [{model, measurements}]
        }

        {{s.calls, s.cap}, s}
      end)

    if n > cap do
      IO.puts("INVARIANT FAILED: live-call cap #{cap} exceeded (#{n})")
      report()
      otel_report()
      System.halt(2)
    end

    :ok
  end

  def calls, do: Agent.get(__MODULE__, & &1.calls)
  def usages, do: Agent.get(__MODULE__, & &1.usages)
  def events(name), do: Agent.get(__MODULE__, &Map.get(&1.events, name, []))

  def api_key! do
    System.get_env("ANTHROPIC_API_KEY") || System.get_env("API_KEY") ||
      raise "Missing API key: set ANTHROPIC_API_KEY or API_KEY"
  end

  def client(extra_options \\ %{}) do
    %Normandy.LLM.ClaudioAdapter{api_key: api_key!(), options: Map.merge(%{timeout: 60_000}, extra_options)}
  end

  def narrate(text), do: IO.puts("\n▸ " <> text)

  def turn(n, user, reply) do
    IO.puts("  [turn #{n}] user:  #{user}")
    IO.puts("  [turn #{n}] agent: #{reply |> to_string() |> String.slice(0, 400)}")
  end

  def assert!(label, true, _msg), do: IO.puts("  ok: #{label}")

  def assert!(label, _falsy, msg) do
    IO.puts("INVARIANT FAILED: #{label} — #{msg}")
    report()
    otel_report()
    System.halt(2)
  end

  def recalls?(text, fact), do: text |> to_string() |> String.downcase() |> String.contains?(String.downcase(fact))

  @doc "Poll `fun` every 50 ms until it returns a truthy value; fail the invariant at the deadline."
  def wait_for(fun, timeout_ms, label) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline, timeout_ms, label)
  end

  defp do_wait(fun, deadline, timeout_ms, label) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) >= deadline do
          assert!(label, false, "not true within #{timeout_ms} ms")
        else
          Process.sleep(50)
          do_wait(fun, deadline, timeout_ms, label)
        end

      value ->
        value
    end
  end

  def finish do
    otel_report()
    report()
  end

  # The usage line and the E2E_RESULT line the runner parses; also printed before a failure
  # halts, so a failed scenario's spend is known too.
  defp report do
    %{id: id, calls: n, t0: t0, priced: priced} = Agent.get(__MODULE__, & &1)
    ms = System.monotonic_time(:millisecond) - t0
    totals = Prices.totals(priced)
    IO.puts("\nLIVE CALLS USED: #{n}")
    IO.puts(Prices.format(totals))

    usage = %{
      input: totals.input,
      output: totals.output,
      cache_read: totals.cache_read,
      cache_write: totals.cache_write,
      cost_usd: Float.round(totals.cost, 6)
    }

    IO.puts("E2E_RESULT " <> Jason.encode!(%{scenario: id, calls: n, ms: ms, usage: usage}))
  end
end
