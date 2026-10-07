# Wave 7 — questions for Q

From the four inventories in this directory (HEAD `0ed6783`): `7.0-code-leftovers.md`,
`7.1-release-docs.md`, `7.3-api-docs-testing.md`, `7.5-release-mechanics.md`. Duplicates merged
(release.yml guard, squash body, Horde floor and `examples/` were each raised twice). Each question
names its source section; the recommendation is first.

## A. Code leftovers

**A1. H10 retry policy** (7.0 Q2). A failed terminal turn-state save leaves the session marked in
flight; a probe showed any eager restart (not only `ResumeReaper`) re-runs the finished turn's model
call and appends a second answer.
- (a) **Recommended.** Log the failure; the server stays alive while the terminal save is unsaved,
  retries it, and refuses new turns with `:persist_failed` until it succeeds; on resume, no model call
  when the answer is already stored. The Known-limits bullet shrinks to one line on process death
  during a store outage.
- (b) Retry once and passivate anyway; the resume guard covers the answered case, but a failed turn's
  model call can run again with no caller.

**A2. Telemetry for a failed terminal save** (7.0 Q1). (a) **Recommended:** a log line by tag only.
(b) a new `[:normandy, :turn, :persist_failed]` event (`phase: :terminal`, catalogue update).

**A3. `chat_message: nil` is a blank answer** (7.0 Q5) → `{:error, %LLMError{type: :invalid_output}}`
on every path. **Recommended yes** (decision 22's "blank is an error"). Breaking only for a client
returning the output struct with `nil`.

## B. Dependencies and platform

**B1. Elixir 1.15/1.16** (7.5 Q8). Verified: `lib/normandy/schema/validator.ex:206` matches
`%Duration{}` unguarded (`Duration` is 1.17+); `type.ex:799` guards the same match. CI tests 1.15 and
1.16. (a) **Recommended:** guard it like `type.ex` (keeps `elixir: "~> 1.15"`). (b) raise the floor to
`~> 1.17` and drop the 1.15/1.16 CI legs (breaking for users on 1.15/1.16).

**B2. Horde floor** (7.0 Q3, 7.5 Q7). `mix.exs:208` allows `~> 0.9`; `SessionRegistry.Horde.Via`
(decision 26a) was checked on 0.10.0 only. (a) **Recommended:** `~> 0.10`. (b) keep `~> 0.9`, document
"verified on 0.10".

**B3. Claudio 0.7.1 contents** (7.5 Q2). The "citations patch" plan-wave-6 R2 expected does not exist
(`claudio` `response.ex:655` drops citations). (a) **Recommended:** write the citations replay patch on
the Claudio branch now, verify live in 7.6. (b) ship 0.7.1 with `add_messages/2` only; add "citations
are not replayed" to the Known limits. **You publish Claudio 0.7.1** either way.

**B4. `@version`** (7.5 Q1). (a) **Recommended:** leave `1.3.0`; cog's bump commit writes `2.0.0`.
(b) set `2.0.0` by hand as plan.md 7.5 says (cog rewrites it anyway).

## C. Docs and MIGRATING

**C1. Which internals to hide** (7.1 Q1). **Recommended:** hide the DX-13 list plus
`Telemetry.KilledRun`, `Agents.ValidationMiddleware`, `Agents.Turn.Driver`; keep `Telemetry.Request`,
`Telemetry.Usage` (adapter contract), `Schema.Validator`, `LLM.StructuredOutputs`,
`Agents.Dispatch(.Invocation/.Pipeline)`, `Turn.Driver.Handlers` public. Alternatives: hide only what
nothing public references, or hide all of DX-13 (loses `Request.span/5`).

**C2. MIGRATING format bar** (7.1 Q2). plan.md says every section has an old→new table and a code
sample; 28 of 42 have neither. (a) **Recommended:** table or sample only where a signature, return
shape or option changes; behaviour changes stay prose (~250 lines). (b) retrofit all 42 (~1000+).
Either way the 12 uncovered API changes and 13 uncovered REL-4 behaviour changes get sections, and the
two breaking items under "New, non-breaking" move.

**C3. "Who is affected" index** at the top of MIGRATING (agent users / adapter authors / behaviour
implementers / store operators, ~25 lines) (7.1 Q3). **Recommended yes.**

**C4. API-diff scripts** (7.1 Q4). (a) **Recommended:** keep in the repo under `tools/api_diff/`,
excluded from the package. (b) only in the investigation file.

**C5. Doc-coverage scope** (7.3 Q1). (a) BaseAgent + Session only (3 docs, plan.md literally);
(b) CLAUDE.md entry-point modules (32); (c) **Recommended:** every module visible after C1, functions,
macros and behaviour callbacks (~100 short docs), pinned by a `Code.fetch_docs` test (`mix docs` cannot
check it: it renders an empty `@doc` without warning).

**C6. CHANGELOG layout** (7.1 Q5). (a) **Recommended (rehearsed):** the hand-written 2.0 block goes
after the first `- - -`, so cog's `## [v2.0.0]` lands directly above it with one 2.0.0 heading.
(b) a post-release docs commit. (c) a cog pre-bump hook.

## D. Testing story

**D1. Shipped test module names** (7.3 Q2; permanent public API). (a) **Recommended:**
`Normandy.Test.FakeClient`, `Normandy.Test.SessionStoreContract`, `Normandy.Test.MemoryStoreContract`
(plan.md; like `Plug.Test`), with a rule that `test/support` never defines a name `lib/` ships.
(b) `Normandy.Testing.*` (devex.md; like `Oban.Testing`).

**D2. Migrate Normandy's own tests to FakeClient** (7.3 Q3). (a) none; (b) **Recommended:** the 3
scripted clients (11 files), then delete them; (c) also StubClient/ModelMockup (79 files).

**D3. Contract API for third parties** (7.3 Q4). **Recommended yes to all three:** a `:new` option
(`{m, f, a}`); `:stored_entry_ids` optional (the 2 delete tests then check the public API only); ship
a 4-test `SessionRegistryContract` too.

## E. Devex Tier 3-4 (each yes/no; 7.3 Q5)

**E1. DX-29 `examples/`** (also 7.0 Q4). Both apps are 1.x and don't compile against 2.0.
**Recommended:** delete `customer_support_app`; delete `agent_horde` (or rewrite it, if you want a
distributed example in 2.0); keep `examples/README.md` pointing at the guides.

**E2. DX-24 `Workflow.execute/1` `:context`** (accepted, never used). **Recommended:** remove it in 2.0
(breaking; MIGRATING line). Alternatives: pass it to `transform`/`when_result`, or document as reserved.

**E3. DX-23 DSL compile-time errors** for `system_prompt` together with
`background`/`steps`/`output_instructions`, and for a missing `model` (code that compiles today stops
compiling). **Recommended yes** in 2.0.

**E4. DX-35** remove `Toolset.filter_by_param_type/2`, `tools_with_constraint/2`,
`filter_by_required_params/2` (no lib callers; breaking). **Recommended remove.**

**E5. DX-20 Postgres migrations.** **Recommended:** docs fix only in 2.0; versioned
`Normandy.Migrations.up(version: n)` in 2.x.

**E6. DX-33 `ModelCatalog.Static`.** **Recommended:** a `Logger.warning` once at `init/1`/`rebuild/3`
when the static catalog answers. Alternative: docs only.

**E7. DX-34 model id in docs.** **Recommended:** `claude-opus-5-5` everywhere (what `lib/` uses).
Alternative: a cheaper Sonnet id in the README quickstart.

## F. Release mechanics (outward-facing)

**F1. release.yml no-bump guard** (7.1 Q6, 7.5 Q5). cog 7.0.0's `bump --auto --dry-run` exits 0 with
nothing to release, so every docs/CI merge to main tries to republish (both Release runs after v1.3.0
failed that way). **Recommended:** fix in Wave 7 (~5 lines: require the dry-run's last line to be a
version).

**F2. Squash message at the 2.0 merge** (7.1 Q7, 7.5 Q6). GitHub defaults the squash body to all 584
commit messages, which include AI `Co-Authored-By` trailers (`6a5f5d0`, `8311a3d`) that cog would show
as an author. (a) **Recommended:** you edit the body in the merge dialog to a short summary plus
`BREAKING CHANGE: see MIGRATING-2.0.md`; the plan's PR task writes that text for you. (b) set the repo's
`squash_merge_commit_message` to `PR_BODY` (affects every PR). Also: disable "Rebase and merge" for the
release (a rebase lands 584 commits and breaks decision 3)? Recommended yes, your call since it is a repo
setting.

**F3. Paused server-tool probe** (7.5 Q3; Known limit). Normandy cannot declare server tools, so this
only arises through the MCP connector. (a) **Recommended:** a Claudio-level probe (real server-tool
response, cut at `pause_turn`, then a user turn) and reword the limit to MCP-connector turns; < $0.20.
(b) a full Normandy scenario through a public MCP server. (c) leave the limit as written.

**F4. AX-7 preserved-thinking probe model** (7.5 Q4). Every scenario runs Haiku 4.5, which doesn't
enforce preserved thinking. **Recommended:** Opus 5.5 with `thinking_block_binding: :error` (~$0.35 per
run). Alternative: Sonnet 5.5 (half the price). Total 7.6 estimate with the full suite: ~$0.75–1.40;
e2e prints no usage today, so the plan adds a usage total to the runner first.

## Q's answers (2026-10-07, one by one) — decision 27

Every recommendation accepted except **F3** (Q chose (b): a full Normandy e2e scenario through the
MCP connector with a public MCP server) and **F2b** ("Rebase and merge" stays enabled; Q picks
"Squash and merge" in the dialog). D3: all three. Controller ruling on E6: DX-33 is the deprecation of
`ModelCatalog.Static`; the warning is one `Logger.warning` per VM (`:persistent_term` flag) when a
config uses it, at `init/1` and `ConfigTemplate.rebuild/3`.
