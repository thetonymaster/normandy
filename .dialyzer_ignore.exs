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

  # a2a/server.ex extract_response_text/1 (lines 148, 158): `response` from BaseAgent.run/2 is
  # always a struct, so the is_binary clause and the non-map catch-all are unreachable defense.
  {"lib/normandy/a2a/server.ex", :guard_fail},
  {"lib/normandy/a2a/server.ex", :pattern_match_cov},

  # --- Tooling false positives ---

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
