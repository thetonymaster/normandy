# BaseAgent.stream/3 with output guards in `:incremental` mode, which rescan the whole
# accumulated text every `chunk_size` bytes, against `:accumulate` (one check at the end)
# and no guards. Settles the agents audit note on the quadratic rescans.
Code.require_file("support.exs", __DIR__)

defmodule Bench.OutputGuards.CountingGuard do
  @moduledoc false
  # Counts its checks in the caller (the stream is consumed there) to prove the
  # incremental path rescans.
  @behaviour Normandy.Guardrails.Guard

  @impl true
  def check(_value, _opts) do
    Process.put(:bench_guard_checks, Process.get(:bench_guard_checks, 0) + 1)
    :ok
  end
end

alias Bench.OutputGuards.CountingGuard
alias Bench.Support
alias Normandy.Agents.BaseAgent
alias Normandy.Guardrails.Builtins.RegexGuard
alias Normandy.Test.FakeClient

# Before any setup, so a bad BENCH_SAVE/BENCH_COMPARE fails at once.
opts = Support.run_opts("output_guards")

chunk_size = 200
regex_guard = {RegexGuard, patterns: [~r/\b\d{3}-\d{2}-\d{4}\b/, ~r/\b(?:\d[ -]?){13,16}\b/]}
sentence = "The quick brown fox jumps over the lazy dog and keeps on running. "

# `bytes` of digit-free prose in 50-byte chunks (the last may be shorter).
chunks = fn bytes ->
  text = binary_part(String.duplicate(sentence, div(bytes, byte_size(sentence)) + 1), 0, bytes)
  for <<c::binary-size(50) <- text>>, do: c
end

config = fn chunks, guardrails ->
  BaseAgent.init(%{
    client: FakeClient.new([{:text, chunks}]),
    model: "claude-opus-5-5",
    guardrails: guardrails
  })
end

stream! = fn config ->
  {:ok, _config, output} = BaseAgent.stream(config, "go", fn _event -> :ok end)
  output
end

sizes = [{"16 KB", 16_384}, {"64 KB", 65_536}, {"256 KB", 262_144}]
inputs = Map.new(sizes, fn {name, bytes} -> {name, chunks.(bytes)} end)

probe = inputs["16 KB"]

output =
  stream!.(
    config.(probe,
      output: [{CountingGuard, []}, regex_guard],
      streaming_mode: :incremental,
      chunk_size: chunk_size
    )
  )

checks = Process.get(:bench_guard_checks, 0)
IO.puts("incremental 16 KB: #{checks} guard checks")

Support.assert!(
  checks in div(16_384, chunk_size)..(div(16_384, chunk_size) + 5),
  "incremental mode must check about every #{chunk_size} bytes (got #{checks} checks for 16 KB)"
)

Support.assert!(
  output.chat_message == Enum.join(probe),
  "the streamed answer must be the joined chunks"
)

Support.banner(
  "BaseAgent.stream/3 output guards (50-byte chunks, chunk_size #{chunk_size})",
  Enum.map(sizes, &elem(&1, 0)),
  "incremental is quadratic in size (rescans the accumulated text at every check); " <>
    "accumulate and no guards are linear. The agents audit measured 3 ms at 64 KB and " <>
    "~52 ms at 256 KB"
)

# The client and config are built outside the timed function: a FakeClient script
# answers one request.
scenario = fn guardrails ->
  {stream!, before_each: fn chunks -> config.(chunks, guardrails) end}
end

Benchee.run(
  %{
    "incremental (RegexGuard x2)" =>
      scenario.(output: [regex_guard], streaming_mode: :incremental, chunk_size: chunk_size),
    "accumulate (RegexGuard x2)" =>
      scenario.(output: [regex_guard], streaming_mode: :accumulate, chunk_size: chunk_size),
    "no guards" => scenario.([])
  },
  Keyword.put(opts, :inputs, inputs)
)
