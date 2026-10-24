# e2e/09_dsl.exs — four DSL agents in a step → parallel → race workflow, executed twice.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S

for {mod, prompt} <- [
      {E2E.S09.Gather, "You summarise any topic in exactly two plain sentences."},
      {E2E.S09.Sentiment, "You label the overall tone of a text as one word: positive, neutral, or negative."},
      {E2E.S09.Topic, "You name the main subject of a text in at most three words."},
      {E2E.S09.Fast, "You answer with a single word."}
    ] do
  Module.create(
    mod,
    quote do
      use Normandy.DSL.Agent

      agent do
        model(unquote(S.model()))
        max_tokens(150)
        system_prompt(unquote(prompt))
      end
    end,
    Macro.Env.location(__ENV__)
  )
end

defmodule E2E.S09.Flow do
  use Normandy.DSL.Workflow

  workflow do
    step :gather do
      agent(E2E.S09.Gather)
    end

    parallel :analyze do
      agent(E2E.S09.Sentiment, name: :sentiment)
      agent(E2E.S09.Topic, name: :topic)
      input(from: :gather)
    end

    race :fastest do
      agent(E2E.S09.Fast, name: :fast1)
      agent(E2E.S09.Fast, name: :fast2)
      input("Name one primary colour.")
    end
  end
end

S.start("09_dsl", cap: 10)

agents =
  Map.new([E2E.S09.Gather, E2E.S09.Sentiment, E2E.S09.Topic, E2E.S09.Fast], fn mod ->
    a = mod.new(client: S.client())
    {mod, a}
  end)

text = fn resp -> resp |> Map.get(:chat_message, inspect(resp)) |> to_string() end

for {input, n} <- Enum.with_index(["the first moon landing", "the history of the bicycle"], 1) do
  S.narrate("Workflow run #{n}: #{input}")
  {:ok, results} = E2E.S09.Flow.execute(agents: agents, initial_input: input)

  S.turn(n, "gather", text.(results.gather))
  S.assert!("run #{n}: gather produced text", String.length(text.(results.gather)) > 0, inspect(results.gather))

  %{sentiment: sentiment, topic: topic} = results.analyze
  S.assert!("run #{n}: both parallel branches succeeded", match?({:ok, _}, sentiment) and match?({:ok, _}, topic), inspect(results.analyze))
  {:ok, s} = sentiment
  {:ok, t} = topic
  IO.puts("  sentiment: #{text.(s)} · topic: #{text.(t)}")

  S.assert!("run #{n}: race returned exactly one unwrapped response", is_map(results.fastest) and not match?({:ok, _}, results.fastest), inspect(results.fastest))
  IO.puts("  fastest: #{text.(results.fastest)}")
end

S.finish()
