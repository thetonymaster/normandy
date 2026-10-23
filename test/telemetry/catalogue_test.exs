defmodule Normandy.TelemetryCatalogueTest do
  # Reads lib/ and the Normandy.Telemetry moduledoc only; nothing is emitted.
  use ExUnit.Case, async: true

  @span_suffixes [:start, :stop, :exception]

  # Call sites whose event name is not a literal list, so the scan cannot read it.
  # Each entry is {file, number of such call sites, the events they emit}. The test
  # fails when a file gains or loses a dynamic call site, so a new dynamically named
  # event cannot be emitted without adding it here and to the catalogue.
  @dynamic [
    # Request.span/5 runs `Span.span(@event, ...)`: one call site, three events.
    {"lib/normandy/telemetry/request.ex", 1,
     [
       [:normandy, :llm, :request, :start],
       [:normandy, :llm, :request, :stop],
       [:normandy, :llm, :request, :exception]
     ]},
    # Span.span/3 and /4 share the emitters `event_prefix ++ [:start | :stop |
    # :exception]`, three call sites. Its callers pass literal prefixes, which the scan reads as `Span.span`
    # calls, so these call sites add no events of their own.
    {"lib/normandy/telemetry/span.ex", 3, []},
    # Turn.Server.stop_run_span/3 emits `[:normandy, :agent, :run, event]` with event
    # :stop or :exception (the :start is a literal elsewhere in the same file).
    {"lib/normandy/agents/turn/server.ex", 1,
     [
       [:normandy, :agent, :run, :stop],
       [:normandy, :agent, :run, :exception]
     ]}
  ]

  @call_site ~r/(?::telemetry\.|\bSpan\.)(execute|span)\(\s*(\[[^\]]*\]|[^\s,)]+)/

  describe "Normandy.Telemetry catalogue" do
    test "every event emitted in lib/ is documented, and every documented event is emitted" do
      emitted = MapSet.new(literal_events() ++ Enum.flat_map(@dynamic, &elem(&1, 2)))
      documented = MapSet.new(documented_events())

      undocumented = MapSet.to_list(MapSet.difference(emitted, documented))
      phantom = MapSet.to_list(MapSet.difference(documented, emitted))

      assert undocumented == [],
             "emitted but not in the Normandy.Telemetry moduledoc: #{inspect(undocumented)}"

      assert phantom == [],
             "in the Normandy.Telemetry moduledoc but never emitted: #{inspect(phantom)}"
    end

    test "the dynamically named call sites are exactly the ones listed" do
      actual =
        for {file, sites} <- call_sites(),
            dynamic = Enum.reject(sites, &match?({_, {:literal, _}}, &1)),
            dynamic != [],
            into: %{},
            do: {file, length(dynamic)}

      expected = Map.new(@dynamic, fn {file, count, _events} -> {file, count} end)

      assert actual == expected
    end

    test "the scan finds the events it is meant to (guards against a broken regex)" do
      events = literal_events()

      assert [:normandy, :agent, :llm_call, :stop] in events
      assert [:normandy, :workflow, :run, :start] in events
      assert [:normandy, :a2a, :request, :exception] in events
      assert [:normandy, :turn, :approval, :stop] in events
      assert [:normandy, :tool, :denied] in events
      assert [:normandy, :agent, :run, :exception] in events
    end

    test "the memory command span's semconv operation names are documented (TEL-14)" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Normandy.Telemetry)

      for name <- ~w(search_memory upsert_memory update_memory delete_memory) do
        assert moduledoc =~ "`#{name}`", "missing gen_ai.operation.name #{name}"
      end
    end
  end

  # {file, [{kind, {:literal, event} | {:dynamic, source}}]}, comments excluded.
  defp call_sites do
    for file <- Path.wildcard("lib/**/*.ex"),
        sites = sites_in(File.read!(file)),
        sites != [],
        do: {file, sites}
  end

  defp sites_in(source) do
    code =
      source
      |> String.split("\n")
      |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
      |> Enum.join("\n")

    for [_, kind, arg] <- Regex.scan(@call_site, code) do
      {String.to_atom(kind), parse_event(arg)}
    end
  end

  defp parse_event("[" <> _ = arg) do
    case Code.string_to_quoted!(arg) do
      list when is_list(list) ->
        if Enum.all?(list, &is_atom/1), do: {:literal, list}, else: {:dynamic, arg}
    end
  end

  defp parse_event(arg), do: {:dynamic, arg}

  # Spans (`:telemetry.span`) emit all three events; executes emit their own name.
  defp literal_events do
    for {_file, sites} <- call_sites(),
        {kind, {:literal, event}} <- sites,
        full <- expand(kind, event),
        do: full
  end

  defp expand(:span, event), do: Enum.map(@span_suffixes, &(event ++ [&1]))
  defp expand(:execute, event), do: [event]

  defp documented_events do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Normandy.Telemetry)

    for [_, list] <- Regex.scan(~r/^### `(\[:normandy[^`]*\])`/m, moduledoc),
        event <- expand_alternatives(list),
        do: event
  end

  # "[:a, :b, :start | :stop]" -> [[:a, :b, :start], [:a, :b, :stop]]
  defp expand_alternatives(list) do
    [last | rest] = list |> String.slice(1..-2//1) |> String.split(", ") |> Enum.reverse()

    prefix = rest |> Enum.reverse() |> Enum.map(&atom/1)

    last
    |> String.split(" | ")
    |> Enum.map(&(prefix ++ [atom(&1)]))
  end

  defp atom(":" <> name), do: String.to_atom(name)
end
