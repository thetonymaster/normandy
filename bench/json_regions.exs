# Normandy.LLM.JsonDeserializer.parse_and_validate/3 on model output that is not bare
# JSON, so it falls back to extracting balanced regions from the prose. Settles
# principles audit llm#1: the extraction is bounded (8 * size + 1024 bytes of regions),
# so it must stay linear on the unclosed-opener input that used to be quadratic.
Code.require_file("support.exs", __DIR__)

alias Bench.Support
alias Normandy.Agents.BaseAgentOutputSchema
alias Normandy.LLM.JsonDeserializer

# Before any setup, so a bad BENCH_SAVE/BENCH_COMPARE fails at once.
opts = Support.run_opts("json_regions")

schema = %BaseAgentOutputSchema{}

prose = "Here is what I found while looking into the request. "
# Balanced braces that are not JSON: each one is a region that fails to decode.
decoy = "```elixir\nfn x -> %{a: x, b: [x, x]} end\n```\n"
answer = ~s({"chat_message": "42"})

# Prose and decoys around one answer object, padded to `bytes`.
balanced = fn bytes ->
  unit = prose <> decoy
  filler = String.duplicate(unit, div(max(bytes - byte_size(answer), 0), byte_size(unit)) + 1)
  half = binary_part(filler, 0, div(bytes, 2))
  half <> answer <> binary_part(filler, 0, max(bytes - byte_size(half) - byte_size(answer), 0))
end

# Openers that never close (the pre-Wave-8 quadratic case), padded to `bytes`.
adversarial = fn bytes ->
  unit = "{\"a\": "
  binary_part(String.duplicate(unit, div(bytes, byte_size(unit)) + 1), 0, bytes)
end

sizes = [{"1 KB", 1_024}, {"30 KB", 30_720}, {"120 KB", 122_880}, {"240 KB", 245_760}]

inputs =
  Map.new(sizes, fn {name, bytes} ->
    {name, %{balanced: balanced.(bytes), adversarial: adversarial.(bytes)}}
  end)

small = inputs["1 KB"]

Support.assert!(
  JsonDeserializer.parse_and_validate(small.balanced, schema) ==
    {:ok, %BaseAgentOutputSchema{chat_message: "42"}},
  "the balanced input must bind its one answer object"
)

{:error, reason} = JsonDeserializer.parse_and_validate(small.adversarial, schema)
reason_tag = if is_tuple(reason), do: elem(reason, 0), else: reason
IO.puts("adversarial 1 KB error: #{inspect(reason_tag)}")

Support.assert!(
  reason_tag != :input_too_large,
  "the adversarial input must reach region extraction, not the input size limit"
)

Support.banner(
  "JsonDeserializer.parse_and_validate/3 region extraction",
  Enum.map(sizes, &elem(&1, 0)),
  "linear in size for both (region budget 8 * size + 1024). Before Wave 8 the " <>
    "adversarial case was quadratic: 30 KB 451 ms ... 240 KB 30 s"
)

Benchee.run(
  %{
    "balanced in prose" => fn input ->
      JsonDeserializer.parse_and_validate(input.balanced, schema)
    end,
    "adversarial unclosed" => fn input ->
      JsonDeserializer.parse_and_validate(input.adversarial, schema)
    end
  },
  Keyword.put(opts, :inputs, inputs)
)
