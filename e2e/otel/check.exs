# e2e/otel/check.exs — checks the traces an `NORMANDY_E2E_OTLP=1 mix e2e` run left in Tempo.
#
#   elixir e2e/otel/check.exs [e2e/reports/<run dir>]     (default: the newest run)
#
# Reads OTEL_TRACE_ID / OTEL_BRIDGE / LIVE CALLS USED from each scenario log, fetches the trace
# from Tempo (TEMPO_URL, default http://localhost:3200) and prints, per scenario, span counts
# and every violation of the rules below. Exit 1 when any scenario has a violation.
#
# Rules (span types by name: "e2e <id>" root, invoke_agent, chat <model>, chat <model> request,
# execute_tool, invoke_workflow, a2a.request, await_approval):
#   * one root; every parent id resolves inside the trace; no other trace carries the scenario
#   * llm_call and tool and approval sit under a run; request under an llm_call
#   * a child starts and ends inside its parent
#   * required GenAI attributes per type; finished llm_calls/requests carry usage + response id
#   * llm_call `normandy.attempts` == its request children; llm_call usage == sum over requests

defmodule E2E.OtelCheck do
  @tempo System.get_env("TEMPO_URL", "http://localhost:3200")

  def main(argv) do
    :inets.start()
    :ssl.start()
    dir = List.first(argv) || newest_run()
    IO.puts("run: #{dir}\n")

    results =
      for log <- Path.wildcard(Path.join(dir, "*.log")) |> Enum.sort() do
        check_scenario(Path.basename(log, ".log"), File.read!(log))
      end

    bad = Enum.count(results, &(&1 != :ok))
    IO.puts("\n#{length(results) - bad}/#{length(results)} scenarios clean")
    System.halt(if bad == 0, do: 0, else: 1)
  end

  defp newest_run, do: Path.wildcard("e2e/reports/*") |> Enum.filter(&File.dir?/1) |> Enum.max()

  defp check_scenario(id, log) do
    trace_id = capture(log, ~r/OTEL_TRACE_ID ([0-9a-f]{32})/)
    bridge = capture(log, ~r/OTEL_BRIDGE (\{.*\})/)
    live = capture(log, ~r/LIVE CALLS USED: (\d+)/)

    if is_nil(trace_id) do
      IO.puts(
        "── #{id}: no OTEL_TRACE_ID in log (scenario crashed before S.start or ran without export)"
      )

      :bad
    else
      spans = fetch_trace(trace_id)
      orphans = orphan_traces(id, trace_id, spans)
      violations = rules(spans) ++ orphan_violations(orphans) ++ bridge_violations(bridge, log)
      summarize(id, trace_id, spans, live, bridge, violations)
      if violations == [], do: :ok, else: :bad
    end
  end

  # --- Tempo ------------------------------------------------------------------------------

  defp fetch_trace(trace_id) do
    %{"trace" => %{"resourceSpans" => rss}} = get!("/api/v2/traces/#{trace_id}")

    for rs <- rss, ss <- rs["scopeSpans"], s <- ss["spans"] do
      %{
        id: s["spanId"],
        parent: s["parentSpanId"],
        name: s["name"],
        type: type(s["name"]),
        kind: s["kind"],
        start: String.to_integer(s["startTimeUnixNano"]),
        stop: String.to_integer(s["endTimeUnixNano"]),
        status: get_in(s, ["status", "code"]),
        attrs: Map.new(s["attributes"] || [], &{&1["key"], value(&1["value"])}),
        events: Enum.map(s["events"] || [], & &1["name"])
      }
    end
  end

  # Only the scenario's own window, so an earlier run of the same scenario does not count.
  defp orphan_traces(scenario, trace_id, spans) do
    q = URI.encode_www_form(~s({span.e2e.scenario="#{scenario}"}))
    root = Enum.find(spans, &(&1.type == :root))
    from = div(root.start, 1_000_000_000)
    to = div(root.stop, 1_000_000_000) + 1

    %{"traces" => traces} =
      get!("/api/search?q=#{q}&limit=1000&start=#{from}&end=#{to}")

    for t <- traces,
        String.trim_leading(t["traceID"], "0") != String.trim_leading(trace_id, "0") do
      "#{t["traceID"]} root=#{inspect(t["rootTraceName"] || t["rootServiceName"])}"
    end
  end

  defp get!(path) do
    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(
        :get,
        {~c"#{@tempo}#{path}", [{~c"accept", ~c"application/json"}]},
        [timeout: 30_000],
        []
      )

    :json.decode(IO.iodata_to_binary(body))
  end

  defp value(%{"stringValue" => v}), do: v
  defp value(%{"intValue" => v}), do: String.to_integer(v)
  defp value(%{"doubleValue" => v}), do: v
  defp value(%{"boolValue" => v}), do: v
  defp value(%{"arrayValue" => %{"values" => vs}}), do: Enum.map(vs, &value/1)
  defp value(%{"arrayValue" => _}), do: []
  defp value(other), do: other

  defp type("e2e " <> _), do: :root
  defp type("invoke_agent" <> _), do: :run
  defp type("invoke_workflow" <> _), do: :workflow
  defp type("execute_tool" <> _), do: :tool
  defp type("a2a.request"), do: :a2a
  defp type("await_approval"), do: :approval

  defp type("chat " <> rest),
    do: if(String.ends_with?(rest, " request"), do: :request, else: :llm_call)

  defp type(_), do: :other

  # --- rules ------------------------------------------------------------------------------

  defp rules(spans) do
    by_id = Map.new(spans, &{&1.id, &1})
    children = Enum.group_by(spans, & &1.parent)

    roots = Enum.filter(spans, &(&1.parent in [nil, ""]))

    root_v =
      case roots do
        [%{type: :root}] -> []
        other -> ["roots: expected the one e2e root, got #{inspect(Enum.map(other, & &1.name))}"]
      end

    root_v ++ Enum.flat_map(spans, &span_rules(&1, by_id, Map.get(children, &1.id, [])))
  end

  defp span_rules(%{type: :root}, _by_id, _children), do: []

  defp span_rules(span, by_id, children) do
    parent = Map.get(by_id, span.parent)

    cond do
      span.parent in [nil, ""] ->
        []

      is_nil(parent) ->
        [v(span, "parent #{span.parent} is not in the trace")]

      true ->
        parent_rule(span, parent) ++
          timing_rule(span, parent) ++
          attr_rules(span) ++
          consistency_rules(span, children)
    end
  end

  @parents %{llm_call: [:run], request: [:llm_call], tool: [:run], approval: [:run]}

  defp parent_rule(span, parent) do
    case Map.fetch(@parents, span.type) do
      {:ok, allowed} ->
        if parent.type in allowed,
          do: [],
          else: [
            v(span, "parent is #{parent.type} (#{parent.name}), expected #{inspect(allowed)}")
          ]

      :error ->
        []
    end
  end

  # 1 ms slack: the bridge ends a span after its telemetry handler ran.
  defp timing_rule(span, parent) do
    slack = 1_000_000

    if span.start + slack >= parent.start and span.stop <= parent.stop + slack,
      do: [],
      else: [
        v(
          span,
          "not inside parent #{parent.name} (start Δ#{ms(span.start - parent.start)} end Δ#{ms(span.stop - parent.stop)})"
        )
      ]
  end

  defp attr_rules(%{type: :run} = s),
    do: require_attrs(s, ~w(gen_ai.operation.name gen_ai.request.model gen_ai.provider.name))

  defp attr_rules(%{type: :llm_call} = s) do
    base =
      require_attrs(
        s,
        ~w(gen_ai.operation.name gen_ai.request.model gen_ai.provider.name gen_ai.request.stream)
      )

    done =
      if ok?(s),
        do:
          require_attrs(
            s,
            ~w(gen_ai.usage.input_tokens gen_ai.usage.output_tokens gen_ai.response.id gen_ai.response.finish_reasons)
          ),
        else: []

    ttfc =
      if ok?(s) and s.attrs["gen_ai.request.stream"] == true,
        do: require_attrs(s, ~w(gen_ai.response.time_to_first_chunk)),
        else: []

    base ++ done ++ ttfc
  end

  defp attr_rules(%{type: :request} = s) do
    base =
      require_attrs(
        s,
        ~w(gen_ai.operation.name gen_ai.request.model gen_ai.provider.name normandy.attempt normandy.request_kind)
      )

    done =
      if ok?(s),
        do:
          require_attrs(
            s,
            ~w(gen_ai.usage.input_tokens gen_ai.usage.output_tokens gen_ai.response.id)
          ),
        else: []

    base ++ done
  end

  defp attr_rules(%{type: :tool} = s),
    do:
      require_attrs(
        s,
        ~w(gen_ai.operation.name gen_ai.tool.name gen_ai.tool.call.id gen_ai.tool.type)
      )

  defp attr_rules(%{type: :workflow} = s),
    do: require_attrs(s, ~w(gen_ai.operation.name normandy.orchestrator))

  defp attr_rules(%{type: :approval} = s), do: require_attrs(s, ~w(normandy.approval.outcome))
  defp attr_rules(_s), do: []

  defp consistency_rules(%{type: :llm_call} = s, children) do
    requests = Enum.filter(children, &(&1.type == :request))
    attempts = s.attrs["normandy.attempts"]

    attempts_v =
      if requests != [] and attempts != length(requests),
        do: [v(s, "normandy.attempts=#{inspect(attempts)} but #{length(requests)} request spans")],
        else: []

    tokens_v =
      for key <- ~w(gen_ai.usage.input_tokens gen_ai.usage.output_tokens),
          requests != [],
          Map.has_key?(s.attrs, key),
          sum = requests |> Enum.map(&Map.get(&1.attrs, key, 0)) |> Enum.sum(),
          sum != s.attrs[key] do
        v(s, "#{key}=#{s.attrs[key]} but its requests sum to #{sum}")
      end

    attempts_v ++ tokens_v
  end

  defp consistency_rules(_s, _children), do: []

  defp require_attrs(s, keys) do
    case Enum.reject(keys, &Map.has_key?(s.attrs, &1)) do
      [] -> []
      missing -> [v(s, "missing #{Enum.join(missing, ", ")}")]
    end
  end

  defp ok?(s), do: s.status != "STATUS_CODE_ERROR"

  defp orphan_violations(orphans),
    do: Enum.map(orphans, &"separate trace for this scenario: #{&1}")

  defp bridge_violations(nil, _log), do: ["no OTEL_BRIDGE line (scenario halted before report)"]

  defp bridge_violations(json, log) do
    case :json.decode(json) do
      %{"errors" => 0} ->
        []

      %{"errors" => n} ->
        ["bridge errors: #{n}" | Regex.scan(~r/  otel bridge error: .*/, log) |> List.flatten()]
    end
  end

  # --- output -----------------------------------------------------------------------------

  defp summarize(id, trace_id, spans, live, bridge, violations) do
    counts =
      spans
      |> Enum.frequencies_by(& &1.type)
      |> Enum.sort()
      |> Enum.map_join(" ", fn {t, n} -> "#{t}=#{n}" end)

    errors = Enum.count(spans, &(not ok?(&1)))

    tokens =
      spans
      |> Enum.filter(&(&1.type == :request))
      |> Enum.map(&Map.get(&1.attrs, "gen_ai.usage.input_tokens", 0))
      |> Enum.sum()

    events =
      spans
      |> Enum.flat_map(& &1.events)
      |> Enum.frequencies()
      |> Enum.map_join(" ", fn {e, n} -> "#{e}×#{n}" end)

    IO.puts("── #{id}  trace #{trace_id}  live calls #{live || "?"}  bridge #{bridge || "-"}")
    IO.puts("   spans: #{counts}  (error status: #{errors}, request input tokens: #{tokens})")
    if events != "", do: IO.puts("   events: #{events}")

    violations
    |> Enum.frequencies()
    |> Enum.each(fn {msg, n} -> IO.puts("   ✗ #{msg}#{if n > 1, do: " (×#{n})", else: ""}") end)
  end

  defp v(s, msg), do: "#{s.name}: #{msg}"
  defp ms(ns), do: "#{Float.round(ns / 1_000_000, 1)}ms"

  defp capture(text, re) do
    case Regex.run(re, text) do
      [_, v] -> v
      _ -> nil
    end
  end
end

E2E.OtelCheck.main(System.argv())
