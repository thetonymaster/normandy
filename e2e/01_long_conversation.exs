# e2e/01_long_conversation.exs — 8 turns of memory, structured output, context and caching.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Components.{AgentMemory, DateTimeProvider, PromptSpecification}

defmodule E2E.S01.Answer do
  use Normandy.Schema

  io_schema "One turn's answer" do
    field(:chat_message, :string, description: "Your reply to the user", required: true)
    field(:facts_remembered, {:array, :string}, description: "Every personal fact the user has told you so far, one per item", required: true)
    field(:fact_count, :integer, description: "How many items are in facts_remembered", required: true)
  end
end

defmodule E2E.S01.OpenMeta do
  use Normandy.Schema

  io_schema "open-map field: incompatible with structured outputs, forces the legacy path" do
    field(:chat_message, :string, description: "Your reply", required: true)
    field(:meta, :map, description: "free-form metadata about your answer", required: true)
  end
end

S.start("01_long_conversation", cap: 12)

# Haiku 4.5 only caches prefixes above a minimum length; pad the system prompt with a
# stable reference block well over it (~6k tokens) so caching can engage.
reference =
  Enum.map_join(1..300, "\n", fn i ->
    "House rule #{String.pad_leading(Integer.to_string(i), 3, "0")}: keep answers short, plain, and grounded in what the user said."
  end)

agent =
  BaseAgent.init(%{
    client: S.client(%{enable_caching: true}),
    model: S.model(),
    max_tokens: 400,
    name: "s01",
    output_schema: struct!(E2E.S01.Answer),
    prompt_specification: %PromptSpecification{
      background: ["You are a concise personal assistant who remembers what the user tells you.", reference],
      output_instructions: ["Track every personal fact the user shares in facts_remembered."]
    }
  })
  |> BaseAgent.register_context_provider(:datetime, %DateTimeProvider{})

today = Date.utc_today() |> Date.to_iso8601()

turns = [
  "My code word is PERIWINKLE-42. Please remember it.",
  "My dog's name is Biscotti.",
  "I live in Ushuaia.",
  "What is today's date? Reply with it in YYYY-MM-DD form exactly as your context gives it.",
  "What is 17 times 3? Just the number.",
  "Name one colour of the rainbow.",
  "What is the capital of Japan? One word.",
  "Tell me my code word, my dog's name and my city."
]

S.narrate("Eight turns on one agent; facts seeded in turns 1-3 must survive to turn 8.")

{agent, replies} =
  turns
  |> Enum.with_index(1)
  |> Enum.map_reduce(agent, fn {text, n}, agent ->
    {agent, r} = BaseAgent.run(agent, %{chat_message: text})
    S.turn(n, text, r.chat_message)

    S.assert!("turn #{n} returns a typed Answer",
      is_struct(r, E2E.S01.Answer) and is_binary(r.chat_message) and is_list(r.facts_remembered) and
        Enum.all?(r.facts_remembered, &is_binary/1) and is_integer(r.fact_count),
      inspect(r)
    )

    {r, agent}
  end)
  |> then(fn {replies, agent} -> {agent, replies} end)

S.assert!("turn 4 reads the date from the DateTimeProvider context", S.recalls?(Enum.at(replies, 3).chat_message, today),
  "expected #{today} in #{inspect(Enum.at(replies, 3).chat_message)}")

last = List.last(replies)
recall_text = Enum.join([last.chat_message | last.facts_remembered], " ")

for fact <- ["PERIWINKLE-42", "Biscotti", "Ushuaia"] do
  S.assert!("turn 8 recalls #{fact}", S.recalls?(recall_text, fact), inspect(last))
end

S.assert!("memory holds 8 user + 8 assistant messages", AgentMemory.count_messages(agent.memory) == 16,
  "got #{AgentMemory.count_messages(agent.memory)}")

[first | rest] = S.usages()

# Call 1 writes the cache on a cold run, or reads it when a run within the cache TTL wrote it.
S.assert!("call 1 engaged the prompt cache (prefix long enough to cache)",
  (Map.get(first, :cache_creation_input_tokens) || 0) + (Map.get(first, :cache_read_input_tokens) || 0) > 0,
  inspect(first))

S.assert!("a later call read from the prompt cache",
  Enum.any?(rest, &((Map.get(&1, :cache_read_input_tokens) || 0) > 0)), inspect(rest))

S.narrate("Structured-outputs kill switch: same schema through the legacy parse path.")

legacy = BaseAgent.init(%{client: S.client(%{structured_outputs: false}), model: S.model(), max_tokens: 300, output_schema: struct!(E2E.S01.Answer)})
{_, r} = BaseAgent.run(legacy, %{chat_message: "I collect stamps. Acknowledge briefly."})
S.turn(1, "I collect stamps.", r.chat_message)
S.assert!("legacy path returns a typed Answer", is_struct(r, E2E.S01.Answer) and is_list(r.facts_remembered), inspect(r))

S.narrate("Open :map field: structured outputs can't express it, so the legacy fallback runs.")

open = BaseAgent.init(%{client: S.client(), model: S.model(), max_tokens: 300, output_schema: struct!(E2E.S01.OpenMeta)})
{_, r} = BaseAgent.run(open, %{chat_message: "Say hello and put any small metadata about your answer in meta."})
S.turn(1, "Say hello (open map)", r.chat_message)
S.assert!("open-map schema falls back and returns a map field", is_struct(r, E2E.S01.OpenMeta) and is_map(r.meta), inspect(r))

S.finish()
