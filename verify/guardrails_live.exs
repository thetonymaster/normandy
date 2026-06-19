Code.require_file("support.exs", __DIR__)
Smoke.Support.start()

defmodule Smoke do
  alias Normandy.Agents.BaseAgent
  alias Normandy.Guardrails.Builtins.{MaxLength, ForbiddenSubstrings}

  def client, do: Smoke.Support.client()
  def model, do: Smoke.Support.model()

  def header(title) do
    IO.puts("\n" <> String.duplicate("=", 72))
    IO.puts("  " <> title)
    IO.puts(String.duplicate("=", 72))
  end

  def extract_text(%Normandy.Agents.BaseAgentOutputSchema{chat_message: m}), do: m || ""

  def extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
  end

  def extract_text(%_{content: c}) when is_binary(c), do: c
  def extract_text(%{content: c}) when is_binary(c), do: c
  def extract_text(other), do: inspect(other)

  def violations_of(map) when is_map(map), do: Map.get(map, :guardrail_violations, [])
  def violations_of(_), do: []

  # ---- 1. Non-streaming, guardrail passes ----
  def scenario_1 do
    header("1. non-streaming, MaxLength(limit: 500, field: :chat_message) — passes")

    agent =
      BaseAgent.init(%{
        client: client(),
        model: model(),
        temperature: 0.0,
        max_tokens: 64,
        output_guardrails: [{MaxLength, limit: 500, field: :chat_message}]
      })

    telemetry_ref = attach_telemetry("scenario-1")

    Smoke.Support.record_call!()
    {_cfg, response} = BaseAgent.run(agent, "Say 'hello' in three words.")
    text = extract_text(response)

    IO.puts("response text: #{inspect(text)}")
    IO.puts("telemetry events received: #{telemetry_count(telemetry_ref)}")
    detach_telemetry(telemetry_ref)
  end

  # ---- 2. Non-streaming, guardrail violates (log-and-continue) ----
  def scenario_2 do
    header("2. non-streaming, MaxLength(limit: 5, field: :chat_message) — violation")

    agent =
      BaseAgent.init(%{
        client: client(),
        model: model(),
        temperature: 0.0,
        max_tokens: 64,
        output_guardrails: [{MaxLength, limit: 5, field: :chat_message}]
      })

    telemetry_ref = attach_telemetry("scenario-2")

    Smoke.Support.record_call!()
    {_cfg, response} = BaseAgent.run(agent, "Write a haiku about the sea.")
    text = extract_text(response)

    IO.puts("response text: #{inspect(text)}")
    IO.puts("response length: #{String.length(text)} chars")
    IO.puts("telemetry events received: #{telemetry_count(telemetry_ref)}")

    detach_telemetry(telemetry_ref)
  end

  # ---- 3. Streaming :accumulate, no violation ----
  def scenario_3 do
    header("3. streaming :accumulate, MaxLength(limit: 2000) — no violation")

    agent =
      BaseAgent.init(%{
        client: client(),
        model: model(),
        temperature: 0.0,
        max_tokens: 64,
        output_guardrails: [{MaxLength, limit: 2000}]
        # :accumulate is default
      })

    deltas = :ets.new(:deltas, [:public])
    :ets.insert(deltas, {:buf, ""})

    callback = fn
      :text_delta, text ->
        [{_, buf}] = :ets.lookup(deltas, :buf)
        :ets.insert(deltas, {:buf, buf <> text})

      _type, _data ->
        :ok
    end

    telemetry_ref = attach_telemetry("scenario-3")

    Smoke.Support.record_call!()
    {_cfg, response} = BaseAgent.stream_response(agent, "Count from 1 to 3.", callback)
    [{_, buf}] = :ets.lookup(deltas, :buf)

    IO.puts("streamed text: #{inspect(buf)}")
    IO.puts("final response text: #{inspect(extract_text(response))}")
    IO.puts("guardrail_violations: #{inspect(violations_of(response))}")
    IO.puts("telemetry events received: #{telemetry_count(telemetry_ref)}")

    detach_telemetry(telemetry_ref)
    :ets.delete(deltas)
  end

  # ---- 4. Streaming :accumulate, violation ----
  def scenario_4 do
    header("4. streaming :accumulate, MaxLength(limit: 5) — violation, log-and-continue")

    agent =
      BaseAgent.init(%{
        client: client(),
        model: model(),
        temperature: 0.0,
        max_tokens: 64,
        output_guardrails: [{MaxLength, limit: 5}]
      })

    deltas = :ets.new(:deltas4, [:public])
    :ets.insert(deltas, {:buf, ""})
    :ets.insert(deltas, {:violation, nil})

    callback = fn
      :text_delta, text ->
        [{_, buf}] = :ets.lookup(deltas, :buf)
        :ets.insert(deltas, {:buf, buf <> text})

      :guardrail_violation, payload ->
        :ets.insert(deltas, {:violation, payload})

      _type, _data ->
        :ok
    end

    telemetry_ref = attach_telemetry("scenario-4")

    Smoke.Support.record_call!()
    {_cfg, response} = BaseAgent.stream_response(agent, "Write a haiku about rain.", callback)
    [{_, buf}] = :ets.lookup(deltas, :buf)
    [{_, violation_cb}] = :ets.lookup(deltas, :violation)

    IO.puts("streamed text: #{inspect(buf)}")
    IO.puts("final text length: #{String.length(extract_text(response))} chars")
    IO.puts("callback :guardrail_violation payload: #{inspect(violation_cb)}")
    IO.puts("response.guardrail_violations count: #{length(violations_of(response))}")
    IO.puts("telemetry events received: #{telemetry_count(telemetry_ref)}")

    detach_telemetry(telemetry_ref)
    :ets.delete(deltas)
  end

  # ---- 5. Streaming :incremental, no violation ----
  def scenario_5 do
    header("5. streaming :incremental, chunk=50, MaxLength(limit: 2000) — no violation")

    agent =
      BaseAgent.init(%{
        client: client(),
        model: model(),
        temperature: 0.0,
        max_tokens: 64,
        output_guardrails: [{MaxLength, limit: 2000}],
        output_guardrails_streaming_mode: :incremental,
        output_guardrails_chunk_size: 50
      })

    deltas = :ets.new(:deltas5, [:public])
    :ets.insert(deltas, {:buf, ""})

    callback = fn
      :text_delta, text ->
        [{_, buf}] = :ets.lookup(deltas, :buf)
        :ets.insert(deltas, {:buf, buf <> text})

      _type, _data ->
        :ok
    end

    telemetry_ref = attach_telemetry("scenario-5")

    Smoke.Support.record_call!()
    {_cfg, response} = BaseAgent.stream_response(agent, "Count from 1 to 3.", callback)
    [{_, buf}] = :ets.lookup(deltas, :buf)

    IO.puts("streamed text: #{inspect(buf)}")
    IO.puts("final text: #{inspect(extract_text(response))}")
    IO.puts("guardrail_violations: #{inspect(violations_of(response))}")
    IO.puts("telemetry events received: #{telemetry_count(telemetry_ref)}")

    detach_telemetry(telemetry_ref)
    :ets.delete(deltas)
  end

  # ---- 6. Streaming :incremental, violation halts mid-stream ----
  def scenario_6 do
    header("6. streaming :incremental, chunk=20, MaxLength(limit: 10) — halts mid-stream")

    agent =
      BaseAgent.init(%{
        client: client(),
        model: model(),
        temperature: 0.0,
        max_tokens: 64,
        output_guardrails: [{MaxLength, limit: 10}],
        output_guardrails_streaming_mode: :incremental,
        output_guardrails_chunk_size: 20
      })

    deltas = :ets.new(:deltas6, [:public])
    :ets.insert(deltas, {:buf, ""})
    :ets.insert(deltas, {:violation, nil})
    :ets.insert(deltas, {:after_violation_deltas, 0})

    callback = fn
      :text_delta, text ->
        [{_, buf}] = :ets.lookup(deltas, :buf)
        [{_, v}] = :ets.lookup(deltas, :violation)
        :ets.insert(deltas, {:buf, buf <> text})

        if v != nil do
          [{_, n}] = :ets.lookup(deltas, :after_violation_deltas)
          :ets.insert(deltas, {:after_violation_deltas, n + 1})
        end

      :guardrail_violation, payload ->
        :ets.insert(deltas, {:violation, payload})

      _type, _data ->
        :ok
    end

    telemetry_ref = attach_telemetry("scenario-6")

    Smoke.Support.record_call!()
    {_cfg, response} = BaseAgent.stream_response(agent, "Tell a short story.", callback)
    [{_, buf}] = :ets.lookup(deltas, :buf)
    [{_, violation_cb}] = :ets.lookup(deltas, :violation)
    [{_, after_n}] = :ets.lookup(deltas, :after_violation_deltas)

    IO.puts("streamed text (#{String.length(buf)} chars): #{inspect(buf)}")
    IO.puts("callback :guardrail_violation payload: #{inspect(violation_cb)}")
    IO.puts("text deltas received AFTER violation fired: #{after_n}")
    IO.puts("response.guardrail_violations count: #{length(violations_of(response))}")
    IO.puts("telemetry events received: #{telemetry_count(telemetry_ref)}")

    Smoke.Support.assert!(
      "incremental halt: no text deltas after violation fired",
      after_n == 0,
      "got #{after_n} deltas after the violation — :incremental did not halt mid-stream"
    )

    # Only assert violation presence against a real model response (stub produces no content
    # and therefore no guardrail violation; the dry-run validates plumbing only).
    if System.get_env("NORMANDY_SMOKE_STUB") != "true" do
      Smoke.Support.assert!(
        "incremental halt: violation recorded on response",
        length(violations_of(response)) > 0,
        "expected a guardrail_violation on the response"
      )
    end

    detach_telemetry(telemetry_ref)
    :ets.delete(deltas)
  end

  # ---- Telemetry plumbing ----
  def attach_telemetry(name) do
    ref = :erlang.make_ref()
    owner = self()
    handler_id = "smoke-#{name}-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:normandy, :agent, :guardrail, :violation],
      fn _event, measurements, metadata, _ ->
        send(owner, {:smoke_telemetry, ref, measurements, metadata})
      end,
      nil
    )

    {handler_id, ref}
  end

  def detach_telemetry({handler_id, _}), do: :telemetry.detach(handler_id)

  def telemetry_count({_, ref}) do
    count_loop(ref, 0)
  end

  defp count_loop(ref, n) do
    receive do
      {:smoke_telemetry, ^ref, measurements, metadata} ->
        IO.puts(
          "  telemetry: count=#{measurements.count} mode=#{inspect(Map.get(metadata, :mode))} streaming=#{inspect(Map.get(metadata, :streaming))}"
        )

        count_loop(ref, n + 1)
    after
      0 -> n
    end
  end
end

Smoke.scenario_1()
Smoke.scenario_2()
Smoke.scenario_3()
Smoke.scenario_4()
Smoke.scenario_5()
Smoke.scenario_6()

IO.puts("\n" <> String.duplicate("=", 72))
IO.puts("  DONE")
IO.puts(String.duplicate("=", 72))
Smoke.Support.report()
