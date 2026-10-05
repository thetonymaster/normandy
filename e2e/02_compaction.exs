# e2e/02_compaction.exs — a pinned 1 200-token window forces :summarize compaction mid-conversation.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Behaviours.{Compactor, Config}

S.start("02_compaction", cap: 18)

agent =
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 300,
    name: "s02",
    behaviours: %Config{
      compactor: {Compactor.WindowManager, [strategy: :summarize, context_window: 1_200, reserved_tokens: 200]}
    }
  })

topics = ["lighthouses", "sourdough bread", "glaciers", "chess openings", "honeybees", "tidal pools", "paper airplanes", "volcanoes"]

turns =
  ["The vault code is TANGERINE-7. Remember it; I will ask later. Reply 'noted'."] ++
    Enum.map(topics, &"In about 120 words, describe #{&1}.") ++
    ["What is the vault code? Answer with the code only."]

S.narrate("Ten turns; the window is small enough that memory must be summarised along the way.")

{_agent, last_reply} =
  turns
  |> Enum.with_index(1)
  |> Enum.reduce({agent, nil}, fn {text, n}, {agent, _} ->
    {:ok, agent, r} = BaseAgent.run(agent, %{chat_message: text})
    S.turn(n, text, r.chat_message)
    {agent, r.chat_message}
  end)

events = S.events([:normandy, :agent, :compaction])
fired = Enum.filter(events, fn {_m, meta} -> meta.compacted end)

S.narrate("Compactor ran #{length(events)} times, compacted #{length(fired)} times.")
S.assert!("the compactor ran on every turn", length(events) >= length(turns), "#{length(events)} runs for #{length(turns)} turns")
S.assert!("compaction fired at least once", fired != [], inspect(events))

S.assert!("every compaction shrank the conversation",
  Enum.all?(fired, fn {m, _} -> m.tokens_after < m.tokens_before end), inspect(fired))

S.assert!("compactions used the :summarize strategy", Enum.all?(fired, fn {_, meta} -> meta.strategy == :summarize end), inspect(fired))
S.assert!("the turn-1 fact survives summarisation", S.recalls?(last_reply, "TANGERINE-7"), inspect(last_reply))

S.finish()
