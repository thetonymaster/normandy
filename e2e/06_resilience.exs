# e2e/06_resilience.exs — injected 529s exhaust retries, open the breaker, then it recovers live.
Code.require_file("support.exs", __DIR__)
Code.require_file("fault_client.ex", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Resilience.CircuitBreaker

S.start("06_resilience", cap: 3)

client = E2E.FaultClient.new(S.client(), [1, 2, 3, 4])

agent =
  BaseAgent.init(%{
    client: client,
    model: S.model(),
    max_tokens: 50,
    name: "s06",
    retry_options: [max_attempts: 2, base_delay: 100, max_delay: 200, jitter: false],
    enable_circuit_breaker: true,
    circuit_breaker_options: [failure_threshold: 2, success_threshold: 1, timeout: 3_000]
  })

breaker = agent.circuit_breaker
input = %{chat_message: "Reply with the single word: ready"}

attempt = fn ->
  try do
    {:ok, BaseAgent.run(agent, input)}
  rescue
    e in Normandy.LLMError -> {:raised, e}
  end
end

S.narrate("Run 1: two injected 529s exhaust the retry budget.")
{:raised, e1} = attempt.()
S.assert!("run 1 raises the overloaded error after retrying", e1.type == :overloaded, inspect(e1))
S.assert!("run 1 made 2 attempts", E2E.FaultClient.converse_calls(client) == 2, "#{E2E.FaultClient.converse_calls(client)}")
S.assert!("one exhausted run leaves the breaker closed", CircuitBreaker.state(breaker) == :closed, inspect(CircuitBreaker.state(breaker)))

S.narrate("Run 2: two more 529s — the second breaker failure opens it.")
{:raised, e2} = attempt.()
S.assert!("run 2 raises overloaded", e2.type == :overloaded, inspect(e2))
S.assert!("the breaker is open", CircuitBreaker.state(breaker) == :open, inspect(CircuitBreaker.state(breaker)))

S.narrate("Run 3: the open breaker fails fast.")
{:raised, e3} = attempt.()
S.assert!("run 3 raises circuit_open", e3.type == :circuit_open, inspect(e3))
S.assert!("run 3 never reached the client", E2E.FaultClient.converse_calls(client) == 4, "#{E2E.FaultClient.converse_calls(client)}")
S.assert!("no live request so far", S.calls() == 0, "#{S.calls()}")

S.narrate("Waiting out the 3 s breaker timeout (the documented open → half-open contract).")
S.wait_for(fn -> CircuitBreaker.state(breaker) == :half_open end, 6_000, "the breaker turns half-open after its timeout")
IO.puts("  ok: the breaker is half-open")

{:ok, {_agent, r}} = attempt.()
S.turn(4, input.chat_message, r.chat_message)
S.assert!("run 4 succeeds against the live API", S.calls() == 1 and is_binary(r.chat_message), inspect(r))
S.assert!("the breaker closed again", CircuitBreaker.state(breaker) == :closed, inspect(CircuitBreaker.state(breaker)))

S.finish()
