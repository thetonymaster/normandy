[
  # Dialyzer false positive - compress_conversation can return early or continue
  {"lib/normandy/context/summarizer.ex", :pattern_match},

  # Supertype warnings - these are overly strict type specs that are intentionally broader
  ~r"is a supertype of the success typing",

  # --- Verified-dead defensive clauses (intentional guards Dialyzer proves unreachable
  # --- given current success typings; kept on purpose, so suppressed rather than deleted).

  # tools/executor.ex check_result/1: BaseTool.run/1's spec allows only {:ok, _} and
  # {:error, _}, but a third-party tool can return anything; the catch-all turns that into
  # an error result instead of crashing the turn (audit SCHEMA-6).
  {"lib/normandy/tools/executor.ex", :pattern_match_cov},

  # llm/call.ex converse/3 and stream/3: Dialyzer trusts the Model protocol's spec, so the
  # catch-all for any other return is "unreachable". A third-party implementation can return
  # anything (a 1.x bare struct, nil); the catch-all raises ArgumentError naming it instead of
  # a MatchError far from the cause.
  {"lib/normandy/llm/call.ex", :pattern_match_cov},

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
