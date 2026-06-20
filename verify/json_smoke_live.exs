# verify/json_smoke_live.exs — live smoke for the JSON / structured-outputs pipeline.
# Run under MIX_ENV=test (stub mode + test fixtures need it).
#   Free dry-run:  NORMANDY_SMOKE_STUB=true MIX_ENV=test mix run verify/json_smoke_live.exs
#   Live (PAID):   MIX_ENV=test mix run verify/json_smoke_live.exs   # needs API_KEY, uses 4 Haiku calls
#
# Verifies (live): structured outputs return schema-valid, correctly-typed, bound
# structs; the kill-switch and an incompatible (open :map) schema both fall back to
# the legacy path. Struct-type checks run in both modes; field-value checks are live-only.
Code.require_file("support.exs", __DIR__)

defmodule JsonSmoke.OpenMapField do
  use Normandy.Schema

  io_schema "open-map field — incompatible with structured outputs, forces legacy fallback" do
    field(:meta, :map, description: "free-form metadata")
  end
end

defmodule JsonSmoke.Runner do
  alias Normandy.Agents.BaseAgent
  alias Normandy.LLM.Json.TestFixtures.MultiField
  alias Normandy.LLM.Json.TestFixtures.RecoveryFixture

  def main do
    Smoke.Support.start()
    live? = Smoke.Support.live?()

    run = fn output_schema, client, prompt ->
      Smoke.Support.record_call!()

      agent =
        BaseAgent.init(%{
          client: client,
          model: Smoke.Support.model(),
          temperature: 0.0,
          max_tokens: 256,
          output_schema: output_schema
        })

      {_cfg, response} = BaseAgent.run(agent, prompt)
      response
    end

    skip = fn label -> IO.puts("  #{label}: skipped (stub)") end

    # --- Scenario 1: structured happy path (default structured-on) ---
    IO.puts("scenario 1: structured happy path")
    r1 = run.(%MultiField{}, Smoke.Support.client(), "Reply with a friendly one-line greeting and the number 3.")
    Smoke.Support.assert!("s1 returns a MultiField struct", match?(%MultiField{}, r1), inspect(r1))

    if live? do
      Smoke.Support.assert!("s1 chat_message is a string", is_binary(r1.chat_message), inspect(r1))
      Smoke.Support.assert!("s1 count is an integer", is_integer(r1.count), inspect(r1))
    else
      skip.("s1 field values")
    end

    # --- Scenario 2: structured typed fields, incl. a string array ---
    IO.puts("scenario 2: structured typed fields")
    r2 =
      run.(
        %RecoveryFixture{},
        Smoke.Support.client(),
        "Set page_text to a one-sentence summary about the ocean, and put three short ocean facts in facts."
      )

    Smoke.Support.assert!("s2 returns a RecoveryFixture struct", match?(%RecoveryFixture{}, r2), inspect(r2))

    if live? do
      Smoke.Support.assert!("s2 page_text is a string", is_binary(r2.page_text), inspect(r2))
      Smoke.Support.assert!("s2 facts is a list", is_list(r2.facts), inspect(r2))
      Smoke.Support.assert!("s2 facts elements are strings", Enum.all?(r2.facts, &is_binary/1), inspect(r2))
      Smoke.Support.assert!("s2 facts is non-empty", length(r2.facts) >= 1, inspect(r2))
    else
      skip.("s2 field values")
    end

    # --- Scenario 3: legacy path via per-client kill-switch ---
    IO.puts("scenario 3: legacy via kill-switch")
    r3 =
      run.(
        %MultiField{},
        Smoke.Support.client(%{structured_outputs: false}),
        "Reply with a friendly one-line greeting and the number 3."
      )

    Smoke.Support.assert!("s3 returns a MultiField struct", match?(%MultiField{}, r3), inspect(r3))

    if live? do
      Smoke.Support.assert!("s3 chat_message is a string", is_binary(r3.chat_message), inspect(r3))
    else
      skip.("s3 field values")
    end

    # --- Scenario 4: incompatible (open :map) schema → gate :skip → legacy ---
    IO.puts("scenario 4: incompatible-schema fallback")
    r4 =
      run.(
        %JsonSmoke.OpenMapField{},
        Smoke.Support.client(),
        "Return a small piece of free-form metadata about yourself in the meta field."
      )

    Smoke.Support.assert!(
      "s4 incompatible schema degrades to legacy and returns the struct",
      match?(%JsonSmoke.OpenMapField{}, r4),
      inspect(r4)
    )

    Smoke.Support.report()
  end
end

JsonSmoke.Runner.main()
