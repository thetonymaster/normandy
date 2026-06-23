[
  # Weather tool uses Erlang :inets and :httpc modules
  ~r"lib/normandy/tools/examples/weather\.ex.*unknown_function.*Function :inets\.start",
  ~r"lib/normandy/tools/examples/weather\.ex.*unknown_function.*Function :httpc\.request",

  # Dialyzer false positive - compress_conversation can return early or continue
  {"lib/normandy/context/summarizer.ex", :pattern_match},

  # Supertype warnings - these are overly strict type specs that are intentionally broader
  ~r"is a supertype of the success typing",

  # --- Verified-dead defensive clauses (intentional guards Dialyzer proves unreachable
  # --- given current success typings; kept on purpose, so suppressed rather than deleted).

  # base_agent.ex call_turn_llm/3 (~line 577): the `{false, %{tool_calls: [_|_]}}` arm strips
  # tool_calls for no-tools agents (no-tools parity contract). Dialyzer infers has_tools?(config)
  # is always true on this path and flags the `false` arm. The Turn FSM does run no-tools agents,
  # so the guard is real. Reported at :1 (construct lives in a with_llm_call_span/3 closure that
  # loses line info), so target line 1 specifically to avoid masking real pattern_match warnings.
  # Reachability + load-bearing proven by test/agents/base_agent_turn_driver_test.exs
  # ("a no-tools agent whose LLM returns tool_calls finalizes without dispatching").
  ~r"base_agent\.ex:1:pattern_match",

  # a2a/server.ex extract_response_text/1 (lines 148, 158): `response` from BaseAgent.run/2 is
  # always a struct, so the is_binary clause and the non-map catch-all are unreachable defense.
  {"lib/normandy/a2a/server.ex", :guard_fail},
  {"lib/normandy/a2a/server.ex", :pattern_match_cov},

  # agents/turn/server.ex fail/2 (line 383): turn_state is always a %Turn.State{} at every call
  # site, so the bare `fail(data, reason)` fallback clause is unreachable defense.
  {"lib/normandy/agents/turn/server.ex", :pattern_match_cov},

  # llm/claudio_adapter.ex extract_usage/1 (line 862): `response` is always a map (Response/
  # Req.Response struct), so the catch-all clause is unreachable defense.
  {"lib/normandy/llm/claudio_adapter.ex", :pattern_match_cov},

  # behaviours/compactor/window_manager.ex run/2 (line 56): WindowManager.ensure_within_limit/2
  # provably returns only {:ok, _} (spec + impl), so the {:error, reason} arm is unreachable defense.
  {"lib/normandy/behaviours/compactor/window_manager.ex", :pattern_match},

  # --- Tooling false positives ---

  # agents/config_template.ex rebuild/3 (line 49): spec returns BaseAgentConfig.t(), which is the
  # correct human contract, but the template arg is an untyped map() so Dialyzer infers field
  # values as term() (broader than t()'s field types) and reports invalid_contract. Not a bug.
  {"lib/normandy/agents/config_template.ex", :invalid_contract},

  # behaviours/session_store/postgres/migration.ex up/0 + down/0 (lines 15, 24, 36): idiomatic
  # Ecto create/index/drop calls discard their return values; :unmatched_returns is just noisy here.
  {"lib/normandy/behaviours/session_store/postgres/migration.ex", :unmatched_return},

  # --- CI-toolchain-specific ---

  # llm/json_deserializer.ex (cast_map/resolve_inner region): a redundant `_` clause the CI
  # Dialyzer (Elixir 1.19 / OTP 28 as resolved by setup-beam on Ubuntu) reports as covered by
  # earlier clauses, but local OTP 28.4 does not emit it. pattern_match_cov flags an *unreachable*
  # clause, so it is behavior-safe; suppressed to keep the gate stable across toolchain drift.
  # (Appears as an unnecessary skip on toolchains that don't emit it — harmless, non-fatal.)
  {"lib/normandy/llm/json_deserializer.ex", :pattern_match_cov}
]
