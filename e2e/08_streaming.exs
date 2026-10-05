# e2e/08_streaming.exs — streamed conversation, then an incremental guardrail stops a stream mid-flight.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Components.AgentMemory
alias Normandy.Guardrails.Builtins.ForbiddenSubstrings

S.start("08_streaming", cap: 5)

{:ok, buf} = Agent.start_link(fn -> %{text: "", violation: nil, after_violation: 0} end)

on_chunk = fn
  :text_delta, text ->
    Agent.update(buf, fn s ->
      s = %{s | text: s.text <> text}
      if s.violation, do: %{s | after_violation: s.after_violation + 1}, else: s
    end)

  :guardrail_violation, payload ->
    Agent.update(buf, &%{&1 | violation: payload})

  _type, _data ->
    :ok
end

reset = fn -> Agent.update(buf, fn _ -> %{text: "", violation: nil, after_violation: 0} end) end
streamed = fn -> Agent.get(buf, & &1) end

agent =
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 200,
    name: "s08",
    output_guardrails: [{ForbiddenSubstrings, terms: ["PINEAPPLE"]}],
    output_guardrails_streaming_mode: :incremental,
    output_guardrails_chunk_size: 20
  })

stream_turn = fn agent, n, text ->
  reset.()
  {:ok, agent, response} = BaseAgent.run(agent, %{chat_message: text}, stream: true, on_chunk: on_chunk)
  s = streamed.()
  S.turn(n, text, s.text)
  {agent, response, s}
end

S.narrate("Three streamed turns; each turn's deltas must rebuild what memory stores.")
{agent, _, s1} = stream_turn.(agent, 1, "My badge id is ORCA-19. Reply 'noted'.")
{agent, _, s2} = stream_turn.(agent, 2, "In two sentences, describe a harbour at dawn.")
{agent, _, s3} = stream_turn.(agent, 3, "What is my badge id? Answer with the id only.")

for {s, n} <- [{s1, 1}, {s2, 2}, {s3, 3}] do
  S.assert!("turn #{n} streamed some text", String.length(s.text) > 0, inspect(s))
end

assistant_texts =
  agent.memory
  |> AgentMemory.messages()
  |> Enum.filter(&(&1.role == "assistant"))
  |> Enum.map(&inspect(&1.content))

S.assert!("memory holds one assistant entry per streamed turn", length(assistant_texts) == 3, inspect(assistant_texts))
S.assert!("turn 2's streamed text is what memory stored",
  S.recalls?(Enum.at(assistant_texts, 1), String.slice(String.trim(s2.text), 0, 40)), inspect({s2.text, Enum.at(assistant_texts, 1)}))
S.assert!("turn 3 recalls the badge id across streamed turns", S.recalls?(s3.text, "ORCA-19"), s3.text)

S.narrate("Turn 4: the model is asked for a forbidden word; the incremental guard halts the stream.")
{_agent, response, s4} = stream_turn.(agent, 4, "Write the word PINEAPPLE ten times, separated by spaces, and nothing else.")
violations = Map.get(response, :guardrail_violations, [])
S.assert!("the violation was recorded on the response", violations != [], inspect(response))
S.assert!("the callback saw the violation", s4.violation != nil, inspect(s4))
S.assert!("no text deltas arrived after the violation fired", s4.after_violation == 0, "#{s4.after_violation} deltas after")

modes =
  S.events([:normandy, :agent, :guardrail, :violation])
  |> Enum.map(fn {_m, meta} -> Map.get(meta, :mode) end)

S.assert!("violation telemetry reports :incremental streaming", :incremental in modes, inspect(modes))

S.finish()
