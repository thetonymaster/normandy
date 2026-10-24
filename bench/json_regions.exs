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

# Prose and decoys around one answer object, about `bytes` long. Whole units only: a cut
# inside a decoy would leave an unclosed brace (the stray-opener case, measured on its own).
balanced = fn bytes ->
  unit = prose <> decoy
  n = div(bytes, byte_size(unit))
  String.duplicate(unit, div(n, 2)) <> answer <> String.duplicate(unit, n - div(n, 2))
end

# The balanced input after one opener that never closes, as in prose like this.
stray = fn bytes -> "Use { to open a block. " <> balanced.(bytes) end

# Openers that never close (the pre-Wave-8 quadratic case), padded to `bytes`.
adversarial = fn bytes ->
  unit = "{\"a\": "
  binary_part(String.duplicate(unit, div(bytes, byte_size(unit)) + 1), 0, bytes)
end

sizes = [{"1 KB", 1_024}, {"30 KB", 30_720}, {"120 KB", 122_880}, {"240 KB", 245_760}]

inputs =
  Map.new(sizes, fn {name, bytes} ->
    {name, %{balanced: balanced.(bytes), stray: stray.(bytes), adversarial: adversarial.(bytes)}}
  end)

small = inputs["1 KB"]

Support.assert!(
  JsonDeserializer.parse_and_validate(small.balanced, schema) ==
    {:ok, %BaseAgentOutputSchema{chat_message: "42"}},
  "the balanced input must bind its one answer object"
)

for {name, input} <- inputs do
  Support.assert!(
    input.balanced |> :binary.matches("{") |> length() ==
      input.balanced |> :binary.matches("}") |> length(),
    "the balanced #{name} input must close every brace"
  )

  Support.assert!(
    JsonDeserializer.parse_and_validate(input.stray, schema) ==
      {:ok, %BaseAgentOutputSchema{chat_message: "42"}},
    "the stray-opener #{name} input must still bind its answer"
  )
end

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
  "linear in size for all three (region budget 8 * size + 1024); one stray opener " <>
    "about 2-2.5x balanced (one extra pass to the end; ~10x before #54). Before Wave 8 " <>
    "the adversarial case was quadratic: 30 KB 451 ms ... 240 KB 30 s"
)

Benchee.run(
  %{
    "balanced in prose" => fn input ->
      JsonDeserializer.parse_and_validate(input.balanced, schema)
    end,
    "one stray opener" => fn input ->
      JsonDeserializer.parse_and_validate(input.stray, schema)
    end,
    "adversarial unclosed" => fn input ->
      JsonDeserializer.parse_and_validate(input.adversarial, schema)
    end
  },
  Keyword.put(opts, :inputs, inputs)
)
