[
  # Dialyzer false positive - compress_conversation can return early or continue
  {"lib/normandy/context/summarizer.ex", :pattern_match},

  # Supertype warnings - these are overly strict type specs that are intentionally broader
  ~r"is a supertype of the success typing",

  # --- Verified-dead defensive clauses (intentional guards Dialyzer proves unreachable
  # --- given current success typings; kept on purpose, so suppressed rather than deleted).

  # tools/executor.ex check_result/1: `Normandy.Tool.run/2`'s spec allows only {:ok, _} and
  # {:error, _}, but a third-party tool can return anything; the catch-all turns that into
  # an error result instead of crashing the turn (audit SCHEMA-6).
  {"lib/normandy/tools/executor.ex", :pattern_match_cov},

  # --- Tooling false positives ---

  # behaviours/session_store/postgres/migration.ex up/0 + down/0 (lines 15, 24, 36): idiomatic
  # Ecto create/index/drop calls discard their return values; :unmatched_returns is just noisy here.
  {"lib/normandy/behaviours/session_store/postgres/migration.ex", :unmatched_return},

  # behaviours/session_store/postgres/migration_add_inflight.ex up/0 + down/0: the same
  # idiomatic Ecto create/drop index calls.
  {"lib/normandy/behaviours/session_store/postgres/migration_add_inflight.ex", :unmatched_return},

  # behaviours/memory_store/postgres/migration.ex up/0 + down/0: the same idiomatic Ecto
  # create/drop calls, two tables (documents and the namespace counters).
  {"lib/normandy/behaviours/memory_store/postgres/migration.ex", :unmatched_return},

  # options.ex describe/2: NimbleOptions.ValidationError types :key as atom(), but an
  # unknown-option error puts the list of unknown keys there (nimble_options 1.1.1,
  # validate_unknown_options/2), so the is_list/1 guard Dialyzer calls impossible is the
  # clause that formats "unknown option :x; supported: ...". Covered by test/options_test.exs.
  {"lib/normandy/options.ex", :guard_fail},

  # options.ex supported/1 (same cause as the guard_fail above): with the is_list/1 clause of
  # describe/2 judged impossible, Dialyzer (OTP 28.4 / Elixir 1.19.5) also reports its only
  # caller-side helper supported/1 as never called. It is called from that clause.
  # Pinned to supported/1 by its message (not file-wide), so other dead code in options.ex
  # is still reported.
  {"lib/normandy/options.ex", "Function supported/1 will never be called."},

  # --- CI-toolchain-specific ---

  # llm/json_deserializer.ex (cast_map/resolve_inner region): a redundant `_` clause the CI
  # Dialyzer (Elixir 1.19 / OTP 28 as resolved by setup-beam on Ubuntu) reports as covered by
  # earlier clauses, but local OTP 28.4 does not emit it. pattern_match_cov flags an *unreachable*
  # clause, so it is behavior-safe; suppressed to keep the gate stable across toolchain drift.
  # (Appears as an unnecessary skip on toolchains that don't emit it — harmless, non-fatal.)
  {"lib/normandy/llm/json_deserializer.ex", :pattern_match_cov}
]
