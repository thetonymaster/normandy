# Fix 3: Tool-Dispatch Persistence, Batch Completeness, and Transcript Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A crash during tool execution must never brick a durable session. Today the assistant `tool_use` message is persisted on entering `:tool_dispatch`, but turn state is not (`lib/normandy/agents/turn.ex:132-135`; the first `{:persist, _}` is emitted at `turn.ex:304`, after the batch completes). A mid-dispatch crash leaves the store with a trailing unanswered `tool_use`; rehydration replays that invalid history verbatim and the next LLM call gets a provider 400. This plan (Plan 2 of the critical-fixes spec, `docs/superpowers/specs/2026-07-01-critical-fixes-design.md`, section "Fix 3") makes four changes: (1) persist turn state on `:tool_dispatch` entry, before any tool runs; (2) assert batch completeness in `apply_tool_results/2` (result ids must equal pending ids, as sets); (3) a new `Turn.resume/1` clause that resolves a persisted `:tool_dispatch` state fail-closed by synthesizing error `tool_result`s (tools NEVER re-execute); (4) rehydration-time transcript repair in `Turn.Session` for dangling `tool_use` with no usable persisted pending state (pre-fix sessions). It introduces `Normandy.Components.TranscriptIntegrity`, the single owner of the `tool_use`/`tool_result` pairing invariant, which Plan 3 (Fix 4) will extend with `snap_cut/2`.

**Architecture:** The turn is a pure FSM (`Normandy.Agents.Turn.step/2` / `resume/1` return `{state, [effect]}` and do no I/O) interpreted by three shells: `Turn.Driver` (sync, powers `BaseAgent.run`), `Turn.Inline` (library/scripted), and `Turn.Server` (async `:gen_statem`, durable sessions). `Turn.Session` routes `session_id` to a live server or rehydrates one from the `SessionStore`. Changes 1-3 live in the pure core (`turn.ex`) — the only new effect emission is one more `{:persist, _}`, which all three interpreters already handle (Driver no-op at `driver.ex:84-86`, Inline no-op at `inline.ex:96-98`, Server writes at `server.ex:294-298`). Change 4 lives in `Turn.Session.rehydrate_and_start/1` and runs against store entries before the server starts. The pairing logic itself lives in the new `Normandy.Components.TranscriptIntegrity` (components layer — it must not depend on `Normandy.Agents.*`), consumed by both `turn.ex` (resume synthesis) and `session.ex` (rehydration repair), and by Plan 3 later.

**Tech Stack:** Elixir, ExUnit

## Global Constraints

- Any change to `Turn.step/2` effects must be handled by all three interpreters (Driver, Inline, Server) — the only new effect emission here is an additional `{:persist, _}`, already handled by all three (verify while implementing).
- Tools NEVER re-execute on resume — fail-closed. Every recovery path answers an interrupted batch with synthesized error `tool_result`s (`is_error: true`); re-dispatch was considered and rejected in the spec (silently double-executes side-effecting tools).
- `mix format` before tests; all existing tests must pass. If an existing test fails, it must be fixed — including tests whose stubs violate the batch-completeness contract this plan makes loud (fix the stub, never weaken the assertion).
- Commits: individual file adds (`git add <path>` per file — `git add .` is forbidden), no AI attribution of any kind in commit messages or bodies.

## Pinned shared interfaces (Plan 3 for Fix 4 consumes these — names must match EXACTLY)

New module `lib/normandy/components/transcript_integrity.ex` — `Normandy.Components.TranscriptIntegrity`:

```elixir
@spec dangling_tool_calls([Normandy.Components.AgentMemory.Entry.t()]) ::
        [Normandy.Components.ToolCall.t()]

@spec synthesized_error_results([Normandy.Components.ToolCall.t() | map()], String.t()) ::
        [Normandy.Components.ToolResult.t()]
# default reason: "interrupted during tool execution" (i.e. arity 1 + arity 2 via \\)
```

Fix 4's plan will ADD `snap_cut/2` to this module — do NOT implement it here, but note it in the moduledoc.

## Cross-plan coordination notes

- **Plan 1 (Fix 1)** changes `session.ex:98` (`ConfigTemplate.from_config/2` → `/3` with `resume_policy`). This plan does NOT touch that line; the rehydration-repair code added here sits before/around it. If Plan 1 has already landed, the `with`-block rewrite in Task 5 must preserve Plan 1's `/3` call — merge accordingly.
- **Plan 3 (Fix 4)** depends on `TranscriptIntegrity` exactly as pinned above. Do not rename, move, or change these signatures.

## Source facts the implementer needs (verified against current source)

| Fact | Location |
|---|---|
| `:tool_dispatch` entry transition (currently NO persist) | `lib/normandy/agents/turn.ex:132-135` |
| `apply_tool_results/2` (batch resolution, shared by normal + approval paths) | `lib/normandy/agents/turn.ex:289-305` |
| `resume/1` catch-all that forces `:failed` (currently catches `:tool_dispatch`) | `lib/normandy/agents/turn.ex:277-280` |
| Driver `{:persist, _}` no-op | `lib/normandy/agents/turn/driver.ex:84-86` |
| Inline `{:persist, _}` no-op | `lib/normandy/agents/turn/inline.ex:96-98` |
| Server `{:persist, _}` write (`persist_turn_state/2`) | `lib/normandy/agents/turn/server.ex:294-298` |
| Server eager auto-resume gate (`resume_policy == :eager and resumable?`) | `lib/normandy/agents/turn/server.ex:97-101` |
| `resumable?/1` already treats `:tool_dispatch` as resumable (not in `[:stopped, :failed]`) | `lib/normandy/agents/turn/server.ex:164-165` |
| Server appends store entries with `turn_id: "live"` | `lib/normandy/agents/turn/server.ex:413-422` |
| `Session.rehydrate_and_start/1` (history load + memory rebuild) | `lib/normandy/agents/turn/session.ex:67-136` |
| Non-template server-opts branch DROPS `:resume_policy` (template branch passes it) | `lib/normandy/agents/turn/session.ex:115-127` vs `session.ex:113` |
| `Entry` struct: `:id, :parent_id, :turn_id, :role, :content` | `lib/normandy/components/agent_memory/entry.ex` |
| `ToolCall` struct: `:id, :name, :input` | `lib/normandy/components/tool_call.ex` |
| `ToolResult` struct: `:tool_call_id, :output, :is_error` (default `false`) | `lib/normandy/components/tool_result.ex` |
| Assistant tool-call content shape: any map/struct with `:tool_calls` (`%ToolCallResponse{}` in prod; plain maps in Driver tests) | `lib/normandy/agents/tool_call_response.ex`, `turn.ex:329-331` |
| Stores round-trip entry `content` as Erlang terms (structs survive; e.g. Postgres `term_to_binary`) | `lib/normandy/behaviours/session_store/postgres.ex:225-226` |

Existing tests that assert the CURRENT (pre-fix) behavior and must be updated in lockstep (details in Tasks 2-3):

- `test/agents/turn_test.exs:171-174` — exact effect list for `:tool_dispatch` entry (will gain `{:persist, s2}`).
- `test/agents/turn_test.exs:178-217` — feeds a result (`"c2"`) with no matching pending call (violates the new completeness contract; fixture gains the pending call).
- `test/agents/turn_driver_test.exs:15, 64-67, 111` — dispatch stubs return results without `tool_call_id` (violate the contract; stubs become real `%ToolResult{}`s).

---

## Task 1: `Normandy.Components.TranscriptIntegrity`

**Files:**
- Create `lib/normandy/components/transcript_integrity.ex`
- Create `test/components/transcript_integrity_test.exs`

**Interfaces (produced — pinned, shared with Plan 3):**
- `dangling_tool_calls(entries :: [Entry.t()]) :: [ToolCall.t()]`
- `synthesized_error_results(calls :: [ToolCall.t() | map()], reason :: String.t() \\ "interrupted during tool execution") :: [ToolResult.t()]`

**Interfaces (consumed):** `%Normandy.Components.AgentMemory.Entry{}` (`:role`, `:content`, `:turn_id`), `%Normandy.Components.ToolCall{}`, `%Normandy.Components.ToolResult{}`. Assistant content exposes tool calls as `:tool_calls` (nil | list) — same duck-typing as `turn.ex:329-331`. Tool entries (`role: "tool"`) carry `%ToolResult{}` (or any map with `:tool_call_id`) as content.

### Steps

- [ ] **1.1 Write the failing unit tests.** Create `test/components/transcript_integrity_test.exs` with exactly this content:

```elixir
defmodule Normandy.Components.TranscriptIntegrityTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Components.TranscriptIntegrity

  defp entry(role, content, turn_id \\ "t1") do
    %Entry{id: UUID.uuid4(), turn_id: turn_id, role: role, content: content}
  end

  defp tool_use_response(calls), do: %ToolCallResponse{content: nil, tool_calls: calls}

  defp result_entry(id) do
    entry("tool", %ToolResult{tool_call_id: id, output: "ok", is_error: false})
  end

  describe "dangling_tool_calls/1" do
    test "empty transcript has no dangling calls" do
      assert TranscriptIntegrity.dangling_tool_calls([]) == []
    end

    test "transcript ending in a user message has no dangling calls" do
      assert TranscriptIntegrity.dangling_tool_calls([entry("user", "hi")]) == []
    end

    test "transcript ending in a plain assistant message has no dangling calls" do
      entries = [
        entry("user", "hi"),
        entry("assistant", %ToolCallResponse{content: "hello", tool_calls: nil})
      ]

      assert TranscriptIntegrity.dangling_tool_calls(entries) == []
    end

    test "trailing assistant tool_use with no results dangles every call, in batch order" do
      calls = [
        %ToolCall{id: "c1", name: "weather", input: %{}},
        %ToolCall{id: "c2", name: "billing", input: %{}}
      ]

      entries = [entry("user", "hi"), entry("assistant", tool_use_response(calls))]

      assert TranscriptIntegrity.dangling_tool_calls(entries) == calls
    end

    test "partially answered trailing batch dangles only the missing calls" do
      calls = [
        %ToolCall{id: "c1", name: "weather", input: %{}},
        %ToolCall{id: "c2", name: "billing", input: %{}}
      ]

      entries = [
        entry("user", "hi"),
        entry("assistant", tool_use_response(calls)),
        result_entry("c1")
      ]

      assert [%ToolCall{id: "c2"}] = TranscriptIntegrity.dangling_tool_calls(entries)
    end

    test "a fully answered trailing batch has no dangling calls" do
      calls = [%ToolCall{id: "c1", name: "weather", input: %{}}]

      entries = [
        entry("user", "hi"),
        entry("assistant", tool_use_response(calls)),
        result_entry("c1")
      ]

      assert TranscriptIntegrity.dangling_tool_calls(entries) == []
    end

    test "an answered batch earlier in the transcript is not the trailing turn's concern" do
      calls = [%ToolCall{id: "c1", name: "weather", input: %{}}]

      entries = [
        entry("user", "hi"),
        entry("assistant", tool_use_response(calls)),
        result_entry("c1"),
        entry("assistant", %ToolCallResponse{content: "done", tool_calls: nil})
      ]

      assert TranscriptIntegrity.dangling_tool_calls(entries) == []
    end

    test "map-shaped tool calls are normalized to ToolCall structs" do
      resp = %{
        content: nil,
        tool_calls: [%{id: "m1", name: "weather", input: %{"city" => "NYC"}}]
      }

      entries = [entry("assistant", resp)]

      assert [%ToolCall{id: "m1", name: "weather", input: %{"city" => "NYC"}}] =
               TranscriptIntegrity.dangling_tool_calls(entries)
    end
  end

  describe "synthesized_error_results/2" do
    test "produces one error result per call, preserving order, with the default reason" do
      calls = [
        %ToolCall{id: "c1", name: "weather", input: %{}},
        %ToolCall{id: "c2", name: "billing", input: %{}}
      ]

      results = TranscriptIntegrity.synthesized_error_results(calls)

      assert [
               %ToolResult{
                 tool_call_id: "c1",
                 is_error: true,
                 output: %{error: "interrupted during tool execution", interrupted: true}
               },
               %ToolResult{tool_call_id: "c2", is_error: true}
             ] = results
    end

    test "accepts a caller-supplied reason" do
      [result] =
        TranscriptIntegrity.synthesized_error_results(
          [%ToolCall{id: "c1", name: "weather", input: %{}}],
          "node handoff"
        )

      assert result.output == %{error: "node handoff", interrupted: true}
      assert result.is_error == true
    end

    test "an empty batch synthesizes nothing" do
      assert TranscriptIntegrity.synthesized_error_results([]) == []
    end
  end
end
```

- [ ] **1.2 Run and watch it fail.**

```
mix format
mix test test/components/transcript_integrity_test.exs
```

Expected outcome: all tests in the file fail with `UndefinedFunctionError` — `Normandy.Components.TranscriptIntegrity.dangling_tool_calls/1 is undefined (module ... is not available)` (plus a compile warning about the unknown module). If they fail for any other reason, STOP and report.

- [ ] **1.3 Implement the module.** Create `lib/normandy/components/transcript_integrity.ex` with exactly this content:

```elixir
defmodule Normandy.Components.TranscriptIntegrity do
  @moduledoc """
  Single owner of the `tool_use`/`tool_result` pairing invariant on a
  conversation transcript.

  A transcript is API-valid only when every assistant `tool_use` block is
  answered by a matching `tool_result` before the next non-tool message. A crash
  between persisting the assistant tool-call message and persisting the batch's
  results leaves a *dangling* trailing `tool_use`; providers reject such a
  history outright, so it must be repaired before the next LLM call — fail-closed
  (synthesized error results), never by re-executing tools.

  Fix 4 (turn-aware truncation) adds `snap_cut/2` here: the turn-boundary
  cut-point invariant shares this module so pairing rules live in one place.
  """

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  @default_reason "interrupted during tool execution"

  @doc """
  Detects a trailing assistant `tool_use` whose results are missing.

  `entries` is a chronological list of `Entry.t()` (the shape returned by
  `SessionStore.history/2` and `AgentMemory.entry_chain/1`). Returns the
  `ToolCall`s — in their original batch order — that have no matching trailing
  `tool_result` entry; `[]` when the transcript ends cleanly.

  Only the *trailing* batch is inspected: an unanswered `tool_use` deeper in the
  history is a truncation defect (Fix 4's `snap_cut/2`), not a crash-repair one.
  """
  @spec dangling_tool_calls([Entry.t()]) :: [ToolCall.t()]
  def dangling_tool_calls(entries) when is_list(entries) do
    {trailing_results, older} =
      entries
      |> Enum.reverse()
      |> Enum.split_while(&tool_entry?/1)

    case older do
      [%Entry{role: "assistant", content: content} | _] ->
        answered = MapSet.new(trailing_results, fn %Entry{content: c} -> result_call_id(c) end)

        content
        |> tool_calls_of()
        |> Enum.map(&to_tool_call/1)
        |> Enum.reject(fn %ToolCall{id: id} -> MapSet.member?(answered, id) end)

      _ ->
        []
    end
  end

  @doc """
  One synthesized error `ToolResult` per call (`is_error: true`), used to answer
  an interrupted batch without re-executing any tool (fail-closed).
  """
  @spec synthesized_error_results([ToolCall.t() | map()], String.t()) :: [ToolResult.t()]
  def synthesized_error_results(calls, reason \\ @default_reason) do
    Enum.map(calls, fn call ->
      %ToolCall{id: id} = to_tool_call(call)

      %ToolResult{
        tool_call_id: id,
        output: %{error: reason, interrupted: true},
        is_error: true
      }
    end)
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp tool_entry?(%Entry{role: "tool"}), do: true
  defp tool_entry?(%Entry{}), do: false

  # Same duck-typing as Turn's tool_calls/1: any map/struct exposing :tool_calls.
  defp tool_calls_of(%{tool_calls: nil}), do: []
  defp tool_calls_of(%{tool_calls: calls}) when is_list(calls), do: calls
  defp tool_calls_of(_), do: []

  # Total: unknown content shapes yield nil, which can never answer a real id.
  defp result_call_id(%{tool_call_id: id}), do: id
  defp result_call_id(_), do: nil

  defp to_tool_call(%ToolCall{} = call), do: call

  defp to_tool_call(%{} = raw) when not is_struct(raw) do
    %ToolCall{
      id: Map.get(raw, :id) || Map.get(raw, "id"),
      name: Map.get(raw, :name) || Map.get(raw, "name"),
      input: Map.get(raw, :input) || Map.get(raw, "input") || %{}
    }
  end
end
```

- [ ] **1.4 Run and watch it pass.**

```
mix format
mix test test/components/transcript_integrity_test.exs
```

Expected outcome: `11 tests, 0 failures`.

```
VERIFY: Ran test/components/transcript_integrity_test.exs — Result: [PASS/FAIL/DID NOT RUN]
```

- [ ] **1.5 Commit.**

```
git add lib/normandy/components/transcript_integrity.ex
git add test/components/transcript_integrity_test.exs
git commit -m "feat(components): add TranscriptIntegrity, owner of the tool_use/tool_result pairing invariant"
```

---

## Task 2: Persist turn state on `:tool_dispatch` entry

**Files:**
- Modify `lib/normandy/agents/turn.ex` (the `calls ->` branch at lines 132-135)
- Modify `test/agents/turn_test.exs` (describe `"step/2 assistant_streaming with tool calls"`, lines 158-176)
- Verify (no changes): `lib/normandy/agents/turn/driver.ex:84-86`, `lib/normandy/agents/turn/inline.ex:96-98`, `lib/normandy/agents/turn/server.ex:294-298`

**Interfaces:** `Turn.step(%State{status: :assistant_streaming}, {:llm_response, resp})` now returns, for the tool-call branch, effects `[{:append_message, "assistant", resp}, {:persist, s2}, {:dispatch_tools, calls}]` where `s2` is the returned state (`status: :tool_dispatch`, `pending_calls: calls`, `last_response: resp`). No new effect *kind* is introduced — `{:persist, State.t()}` already exists (emitted at `turn.ex:187` and `turn.ex:304`).

### Steps

- [ ] **2.1 Update the effect-list test and add the persistence-ordering test (failing first).** In `test/agents/turn_test.exs`, replace the whole describe block `"step/2 assistant_streaming with tool calls"` (lines 158-176) with:

```elixir
  describe "step/2 assistant_streaming with tool calls" do
    test "transitions to :tool_dispatch, appends assistant, persists, dispatches the calls" do
      s = %State{status: :assistant_streaming, iterations_left: 5, max_iterations: 5}
      calls = [%ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}]
      resp = %ToolCallResponse{content: nil, tool_calls: calls}

      {s2, effects} = Turn.step(s, {:llm_response, resp})

      assert s2.status == :tool_dispatch
      assert s2.pending_calls == calls
      assert s2.last_response == resp
      refute s2.stop_reason

      assert effects == [
               {:append_message, "assistant", resp},
               {:persist, s2},
               {:dispatch_tools, calls}
             ]
    end

    test "the state persisted on dispatch entry carries the pending batch (Fix 3)" do
      s = %State{status: :assistant_streaming, iterations_left: 5, max_iterations: 5}
      calls = [%ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}]
      resp = %ToolCallResponse{content: nil, tool_calls: calls}

      {_s2, effects} = Turn.step(s, {:llm_response, resp})

      assert {:persist, persisted} = Enum.find(effects, &match?({:persist, _}, &1))
      assert persisted.status == :tool_dispatch
      assert persisted.pending_calls == calls

      # append (durable tool_use) → persist (durable pending state) → dispatch:
      # a crash between any two leaves the store either consistent or repairable.
      append_idx = Enum.find_index(effects, &match?({:append_message, "assistant", _}, &1))
      persist_idx = Enum.find_index(effects, &match?({:persist, _}, &1))
      dispatch_idx = Enum.find_index(effects, &match?({:dispatch_tools, _}, &1))
      assert append_idx < persist_idx and persist_idx < dispatch_idx
    end
  end
```

- [ ] **2.2 Run and watch both fail.**

```
mix format
mix test test/agents/turn_test.exs
```

Expected outcome: exactly 2 failures, both in the describe above — the effect list has no `{:persist, _}` element (`Enum.find` returns `nil`, and the `==` assertion shows the two-element list). All other tests in the file still pass.

- [ ] **2.3 Implement the persist-on-entry transition.** In `lib/normandy/agents/turn.ex`, replace the `calls ->` branch of the `:assistant_streaming` clause (lines 132-135):

```elixir
      calls ->
        {%{s | status: :tool_dispatch, last_response: resp, pending_calls: calls},
         [{:append_message, "assistant", resp}, {:dispatch_tools, calls}]}
```

with:

```elixir
      calls ->
        # Persist BEFORE dispatching (Fix 3): the durable state must carry the
        # pending batch before any tool runs, so a crash mid-execution leaves a
        # resumable :tool_dispatch state instead of a bare dangling tool_use
        # that rehydration replays verbatim into a provider 400. Effect order is
        # append (durable tool_use) → persist (durable pending state) → dispatch.
        s2 = %{s | status: :tool_dispatch, last_response: resp, pending_calls: calls}
        {s2, [{:append_message, "assistant", resp}, {:persist, s2}, {:dispatch_tools, calls}]}
```

- [ ] **2.4 Verify all three interpreters handle `{:persist, _}` (read, do not edit).**
  - `lib/normandy/agents/turn/driver.ex:84-86` — `{:persist, _turn_state} ->` no-op (`run(acc, state, rest, handlers)`), comment: "Inline driver has no SessionStore/passivation; persistence is a no-op."
  - `lib/normandy/agents/turn/inline.ex:96-98` — `{:persist, _turn_state} ->` no-op (`process(state, rest, deps)`).
  - `lib/normandy/agents/turn/server.ex:294-298` — `{:persist, turn_state} ->` calls `persist_turn_state(data, turn_state)`; on `{:error, reason}` fails the turn with `{:persist_failed, reason}`.

  If any of the three clauses is missing, STOP — that is the `CaseClauseError` trap from the cross-cutting constraint (and the "three interpreters" memory note). All three exist as of this writing; this checkbox is the required verification.

- [ ] **2.5 Run the FSM and interpreter suites, then the full suite.**

```
mix format
mix test test/agents/turn_test.exs test/agents/turn_driver_test.exs \
  test/agents/turn_inline_test.exs test/agents/turn_property_test.exs \
  test/agents/turn_compaction_test.exs test/agents/turn_approval_test.exs \
  test/agents/turn/
mix test
```

Expected outcome: 0 failures everywhere. Notes on why nothing else breaks: the Server's `AssistantAppendFailStore` test (`test/agents/turn/server_test.exs:161-189`) fails the *append* effect, which precedes the new persist, so the interpreter never reaches it; the property tests assert effect-list shape generically, not element-for-element.

```
VERIFY: Ran mix test — Result: [PASS/FAIL/DID NOT RUN]
```

- [ ] **2.6 Commit.**

```
git add lib/normandy/agents/turn.ex
git add test/agents/turn_test.exs
git commit -m "feat(turn): persist turn state on :tool_dispatch entry, before any tool runs"
```

---

## Task 3: Batch-completeness assertion in `apply_tool_results/2`

**Files:**
- Modify `lib/normandy/agents/turn.ex` (`apply_tool_results/2`, lines 289-305 pre-Task-2 numbering)
- Modify `test/agents/turn_test.exs` (new describe; fix the fixture at lines 178-217 that violates the contract)
- Modify `test/agents/turn_driver_test.exs` (three dispatch stubs return results without `tool_call_id`)

**Interfaces:** `apply_tool_results/2` is private but is the shared funnel for `{:tool_results, _}` (`turn.ex:151-153`), the all-rejected approval path (`turn.ex:217`), and `{:approved_results, _}` (`turn.ex:230-235`). New observable contract: when `MapSet` of result `tool_call_id`s ≠ `MapSet` of `pending_calls` ids, `step/2` returns `{%State{status: :failed, error: reason}, [{:fail, reason}]}` with `reason = {:incomplete_batch, %{missing: [...], unexpected: [...]}}` (both lists sorted). Id extraction is total: any map/struct with `:id` (calls) / `:tool_call_id` (results); anything else contributes `nil` and therefore fails the comparison loudly instead of crashing the pure core.

### Steps

- [ ] **3.1 Write the failing assertion tests.** In `test/agents/turn_test.exs`, add this describe block after `"step/2 tool_dispatch with results (under the cap)"`:

```elixir
  describe "step/2 batch-completeness assertion" do
    test "a result batch missing a pending id fails with :incomplete_batch" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        pending_calls: [
          %ToolCall{id: "c1", name: "weather", input: %{}},
          %ToolCall{id: "c2", name: "billing", input: %{}}
        ]
      }

      results = [%ToolResult{tool_call_id: "c1", output: "ok", is_error: false}]

      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :failed
      assert s2.error == {:incomplete_batch, %{missing: ["c2"], unexpected: []}}
      assert effects == [{:fail, {:incomplete_batch, %{missing: ["c2"], unexpected: []}}}]
      # The batch did NOT complete: no decrement, nothing appended.
      assert s2.iterations_left == 5
    end

    test "a result batch with an unknown id fails with :incomplete_batch" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        pending_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}]
      }

      results = [
        %ToolResult{tool_call_id: "c1", output: "ok", is_error: false},
        %ToolResult{tool_call_id: "zz", output: "??", is_error: false}
      ]

      {s2, _effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :failed
      assert s2.error == {:incomplete_batch, %{missing: [], unexpected: ["zz"]}}
    end

    test "missing and unexpected ids are reported together, sorted" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 3,
        max_iterations: 5,
        pending_calls: [
          %ToolCall{id: "b", name: "t", input: %{}},
          %ToolCall{id: "a", name: "t", input: %{}}
        ]
      }

      results = [
        %ToolResult{tool_call_id: "z", output: "?", is_error: false},
        %ToolResult{tool_call_id: "y", output: "?", is_error: false}
      ]

      {s2, _} = Turn.step(s, {:tool_results, results})

      assert s2.error == {:incomplete_batch, %{missing: ["a", "b"], unexpected: ["y", "z"]}}
    end

    test "an exactly matching batch (any order) passes and reaches :steering" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        pending_calls: [
          %ToolCall{id: "c1", name: "weather", input: %{}},
          %ToolCall{id: "c2", name: "billing", input: %{}}
        ]
      }

      results = [
        %ToolResult{tool_call_id: "c2", output: "ok", is_error: false},
        %ToolResult{tool_call_id: "c1", output: "ok", is_error: false}
      ]

      {s2, _effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :steering
      assert s2.iterations_left == 4
    end
  end
```

- [ ] **3.2 Fix the two existing fixtures that violate the contract (same edit session — they are part of the RED run otherwise).**

  (a) `test/agents/turn_test.exs`, describe `"step/2 tool_dispatch with results (under the cap)"`: the state has `pending_calls: [%ToolCall{id: "c1", ...}]` but the results include `tool_call_id: "c2"`. Change the `pending_calls` line:

```elixir
        pending_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}]
```

  to:

```elixir
        pending_calls: [
          %ToolCall{id: "c1", name: "weather", input: %{}},
          %ToolCall{id: "c2", name: "search", input: %{}}
        ]
```

  (b) `test/agents/turn_driver_test.exs`: add `alias Normandy.Components.ToolResult` under the existing aliases (line 6), then update the three dispatch stubs so every result carries the call's id (the calls in this file are plain maps `%{id: "c1"}`, so `&1.id` works):

  - Line 15 (in `recording_handlers/1`):

```elixir
      dispatch_tools: fn _acc, calls ->
        Enum.map(calls, &%ToolResult{tool_call_id: &1.id, output: "ok"})
      end,
```

  - Lines 64-67 (tool-loop test):

```elixir
      dispatch_tools: fn _acc, calls ->
        send(pid, {:dispatched, length(calls)})
        Enum.map(calls, fn c -> %ToolResult{tool_call_id: c.id, output: %{result: :ok}} end)
      end,
```

  - Line 111 (compact test):

```elixir
      dispatch_tools: fn _acc, calls ->
        Enum.map(calls, fn c -> %ToolResult{tool_call_id: c.id, output: %{ok: true}} end)
      end,
```

- [ ] **3.3 Run and watch the new tests fail (and only them).**

```
mix format
mix test test/agents/turn_test.exs test/agents/turn_driver_test.exs
```

Expected outcome: the 3 mismatch tests in `"step/2 batch-completeness assertion"` fail — currently `step/2` happily reaches `:steering` (`s2.status == :failed` assertion fails). The exact-match test and every updated fixture/stub test pass. If anything else fails, STOP and report.

- [ ] **3.4 Implement the assertion.** In `lib/normandy/agents/turn.ex`, replace `apply_tool_results/2` (the whole private function) with:

```elixir
  # The batch-results transition, shared by the normal `:tool_dispatch` path and
  # the approval-resume paths. First enforces the batch-completeness contract:
  # the Claude API rejects a next request unless every tool_use is answered by
  # exactly its tool_result, so a mismatched batch is a shell bug that must fail
  # loudly here — not surface as a provider 400 one call later.
  defp apply_tool_results(%State{} = s, results) do
    expected = MapSet.new(s.pending_calls, &call_id/1)
    actual = MapSet.new(results, &result_call_id/1)

    if MapSet.equal?(actual, expected) do
      do_apply_tool_results(s, results)
    else
      reason =
        {:incomplete_batch,
         %{
           missing: expected |> MapSet.difference(actual) |> Enum.sort(),
           unexpected: actual |> MapSet.difference(expected) |> Enum.sort()
         }}

      {%{s | status: :failed, error: reason}, [{:fail, reason}]}
    end
  end

  # Appends each result, decrements the iteration counter exactly once per batch,
  # emits the steering boundary event, then parks in `:steering` and asks the
  # shell to (maybe) compact before the next LLM call. The continue-vs-forced-final
  # decision is deferred to the `:compaction_done` clauses above. Always clears the
  # per-batch scratch fields (`pending_calls`, `parked_calls`, `held_results`); on
  # the normal path the latter two are empty.
  defp do_apply_tool_results(%State{} = s, results) do
    new_left = s.iterations_left - 1
    append_effects = Enum.map(results, fn r -> {:append_message, "tool", r} end)
    steering = {:emit_event, :steering, %{iterations_left: new_left}}

    s2 = %{
      s
      | status: :steering,
        iterations_left: new_left,
        pending_calls: [],
        parked_calls: [],
        held_results: []
    }

    {s2,
     append_effects ++ [steering, {:persist, s2}, {:maybe_compact, %{iterations_left: new_left}}]}
  end

  # Total id extraction: any map/struct exposing the field counts; anything else
  # contributes nil, which fails the set comparison loudly instead of crashing
  # the pure core (step/2 stays a total function).
  defp call_id(%{id: id}), do: id
  defp call_id(_), do: nil

  defp result_call_id(%{tool_call_id: id}), do: id
  defp result_call_id(_), do: nil
```

Note: the body of `do_apply_tool_results/2` is the OLD `apply_tool_results/2` body, verbatim — only the doc comment moved. Do not change `reorder/2`, `rejection_result/1`, or any callers; they all keep calling `apply_tool_results/2`.

- [ ] **3.5 Run the FSM suites, then the full suite.**

```
mix format
mix test test/agents/turn_test.exs test/agents/turn_driver_test.exs \
  test/agents/turn_inline_test.exs test/agents/turn_property_test.exs \
  test/agents/turn_compaction_test.exs test/agents/turn_approval_test.exs \
  test/agents/turn/
mix test
```

Expected outcome: 0 failures. Why the rest of the suite survives: production dispatch paths (`BaseAgent.dispatch_turn_tools/2`, `Turn.Server.dispatch/2` + `execute_approved/2`, `Dispatch.dispatch_one/3`) produce exactly one `%ToolResult{}` per call with the call's id, and the approval paths merge `held ++ rejected/approved` over the same `pending_calls`. The property test's random-state cases (e.g. `:tool_dispatch` with empty `pending_calls` fed `{:tool_results, [result "c"]}`) now land in `:failed` — which its invariants (`status in @statuses`, `iterations_left` non-increasing, no raise) still accept. Any OTHER test failing with `:incomplete_batch` means a stub violates the batch contract — fix the stub (as in 3.2), never the assertion.

```
VERIFY: Ran mix test — Result: [PASS/FAIL/DID NOT RUN]
```

- [ ] **3.6 Commit.**

```
git add lib/normandy/agents/turn.ex
git add test/agents/turn_test.exs
git add test/agents/turn_driver_test.exs
git commit -m "feat(turn): enforce batch completeness in apply_tool_results"
```

---

## Task 4: `Turn.resume/1` clause for a persisted `:tool_dispatch` state

**Files:**
- Modify `lib/normandy/agents/turn.ex` (add alias; new `resume/1` clause; update `resume/1` @doc; the catch-all at lines 277-280 stays but no longer sees `:tool_dispatch`)
- Modify `test/agents/turn/resume_test.exs`

**Interfaces:**
- Consumes `TranscriptIntegrity.synthesized_error_results/1` (Task 1) and the assertion-guarded `apply_tool_results/2` (Task 3).
- Produces: `Turn.resume(%State{status: :tool_dispatch, pending_calls: calls})` returns the same shape as a completed batch — `{%State{status: :steering, ...}, [{:append_message, "tool", %ToolResult{is_error: true, ...}}, ..., {:emit_event, :steering, _}, {:persist, s2}, {:maybe_compact, _}]}` — so every shell that already interprets a tool batch (notably `Turn.Server`'s `:internal :resume` at `server.ex:200-203`) needs NO new wiring.
- `Turn.Server.resumable?/1` (`server.ex:164-165`) already returns `true` for `:tool_dispatch`; no server change is needed.

### Steps

- [ ] **4.1 Write the failing resume tests.** In `test/agents/turn/resume_test.exs`, extend the alias block and add three tests. Replace the file's header:

```elixir
defmodule Normandy.Agents.Turn.ResumeTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
```

with:

```elixir
defmodule Normandy.Agents.Turn.ResumeTest do
  use ExUnit.Case, async: true
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
```

and add these tests before the final `end`:

```elixir
  test "resume from :tool_dispatch synthesizes error results and reaches :steering" do
    calls = [
      %ToolCall{id: "c1", name: "weather", input: %{}},
      %ToolCall{id: "c2", name: "billing", input: %{}}
    ]

    s = %State{
      status: :tool_dispatch,
      pending_calls: calls,
      iterations_left: 3,
      max_iterations: 5,
      response_model: :rm,
      output_schema: :os
    }

    {s2, effects} = Turn.resume(s)

    assert s2.status == :steering
    assert s2.iterations_left == 2
    assert s2.pending_calls == []

    # One synthesized error result per pending call, in batch order — the batch
    # is answered completely (fail-closed: tools are NEVER re-executed).
    appended = for {:append_message, "tool", r} <- effects, do: r
    assert Enum.map(appended, & &1.tool_call_id) == ["c1", "c2"]
    assert Enum.all?(appended, & &1.is_error)

    assert Enum.all?(appended, fn %ToolResult{output: %{error: reason}} ->
             reason == "interrupted during tool execution"
           end)

    # No re-dispatch effect anywhere in the resume.
    refute Enum.any?(effects, &match?({:dispatch_tools, _}, &1))

    assert Enum.any?(effects, &match?({:persist, %State{status: :steering}}, &1))
    assert List.last(effects) == {:maybe_compact, %{iterations_left: 2}}
  end

  test "resume from :tool_dispatch then :compaction_done continues the turn normally" do
    s = %State{
      status: :tool_dispatch,
      pending_calls: [%ToolCall{id: "c1", name: "weather", input: %{}}],
      iterations_left: 3,
      max_iterations: 5,
      response_model: :rm,
      output_schema: :os
    }

    {s2, _} = Turn.resume(s)
    {s3, effects} = Turn.step(s2, {:compaction_done, %{}})

    assert s3.status == :assistant_streaming
    assert {:call_llm, %{response_model: :rm, final: false}} = List.last(effects)
  end

  test "statuses without a durable resume point still fail loudly" do
    for status <- [:provisioning, :assistant_streaming, :finalizing] do
      s = %State{status: status, iterations_left: 2, max_iterations: 5}
      {s2, effects} = Turn.resume(s)
      assert s2.status == :failed
      assert s2.error == {:unresumable_state, status}
      assert effects == [{:fail, {:unresumable_state, status}}]
    end
  end
```

- [ ] **4.2 Run and watch the two `:tool_dispatch` tests fail.**

```
mix format
mix test test/agents/turn/resume_test.exs
```

Expected outcome: 2 failures — `Turn.resume/1` currently hits the catch-all, so `s2.status == :failed` with `error == {:unresumable_state, :tool_dispatch}` instead of `:steering`. The catch-all test (`:provisioning`/`:assistant_streaming`/`:finalizing`) and the three pre-existing tests pass.

- [ ] **4.3 Implement the resume clause.** In `lib/normandy/agents/turn.ex`:

  (a) Add the alias below the existing ones (after `alias Normandy.Components.ToolResult` at line 24):

```elixir
  alias Normandy.Components.TranscriptIntegrity
```

  (b) Replace the `resume/1` @doc (lines 259-266) with:

```elixir
  @doc """
  Re-derives the effects to continue a turn from a **persisted, non-terminal**
  state (used by an eager shell after passivation/handoff). Pure.

  Resumable states: `:steering` (per-batch boundary) re-issues compaction then
  continues; `:awaiting_approval` waits for a decision (no effects);
  `:tool_dispatch` (persisted on dispatch entry, before any tool ran) resolves
  **fail-closed** — every pending call is answered with a synthesized error
  `tool_result` (tools NEVER re-execute on resume) and the completed batch flows
  through the normal `apply_tool_results` path to `:steering`, leaving the LLM
  to decide whether to retry. Terminal states yield no effects.
  """
```

  (c) Add the new clause between the `:steering` clause (lines 268-270) and the `:awaiting_approval` clause (line 272):

```elixir
  # A crash mid-dispatch: the persisted state carries the pending batch, but the
  # tools' outcomes are unknown (some may have run, some not — the store has no
  # results). Fail closed: synthesize one error result per pending call and run
  # them through the normal batch path. Re-dispatch was rejected in the design —
  # it silently double-executes side-effecting tools.
  def resume(%State{status: :tool_dispatch, pending_calls: calls} = s) do
    apply_tool_results(s, TranscriptIntegrity.synthesized_error_results(calls))
  end
```

  The catch-all at (pre-edit) lines 277-280 is intentionally left in place — with the new clause above it, `:tool_dispatch` can no longer reach it, which is exactly the spec's "remove `:tool_dispatch` from the catch-all".

- [ ] **4.4 Run and watch everything pass, then the full suite.**

```
mix format
mix test test/agents/turn/resume_test.exs
mix test
```

Expected outcome: `6 tests, 0 failures` in resume_test.exs; 0 failures overall (the eager-resume integration tests in `test/agents/turn/eager_resume_test.exs` and the reaper tests only ever seed `:steering` states, so they are unaffected).

```
VERIFY: Ran mix test — Result: [PASS/FAIL/DID NOT RUN]
```

- [ ] **4.5 Commit.**

```
git add lib/normandy/agents/turn.ex
git add test/agents/turn/resume_test.exs
git commit -m "feat(turn): resume a persisted :tool_dispatch state fail-closed via synthesized error results"
```

---

## Task 5: Rehydration repair in `Turn.Session.rehydrate_and_start/1`

**Files:**
- Modify `lib/normandy/agents/turn/session.ex` (aliases; rewrite `rehydrate_and_start/1` lines 67-136 as a `with`; new private helpers; thread `:resume_policy` through the non-template server-opts branch at lines 115-127)
- Create `test/agents/turn/tool_dispatch_recovery_test.exs`

**Interfaces:**
- Consumes `TranscriptIntegrity.dangling_tool_calls/1` + `synthesized_error_results/1` (Task 1), `SessionStore.append_entry/3` and `history/2` (`lib/normandy/behaviours/session_store.ex:28-30`), `%Turn.State{}` (for the "usable pending state" check).
- Repair decision (the spec's "no usable persisted pending state", made precise): repair at rehydration **unless** an eager resume will consume the persisted pending batch — i.e. unless `resume_policy == :eager` AND the persisted state is `:tool_dispatch`/`:awaiting_approval` with `pending_calls` covering every dangling id. Rationale, spelled out because it is load-bearing:
  - **Eager + usable state:** `Turn.resume/1` (Task 4) synthesizes and appends the results exactly once. Repairing here too would double-answer the batch (API-invalid duplicate `tool_result`s). Defer.
  - **Lazy (the default) + any state:** no resume ever runs (`server.ex:97-101` gates on `:eager`), so deferring would leave the 400 in place — the exact headline defect. Repair now. The stale `:tool_dispatch` turn state is harmless: the next turn's first persist overwrites it, and the reaper only touches eager sessions.
  - **No/terminal/other state (pre-fix sessions, first-batch crashes with `turn_state = nil`):** nothing can consume the batch. Repair now.
  - **`:awaiting_approval` is included in "usable":** its persisted `held_results`/`parked_calls` answer the batch when the approval (or its expiry) resolves — repairing under an eager resume of that state would also double-answer. Under lazy, repair is safe: a rehydrated lazy server sits in `:idle`, where stale approval casts are dropped (`server.ex:246-248`).
  - **Self-healing:** if an eager resume crashes before appending, the turn state persists as `:failed` (terminal), so the NEXT rehydration takes the repair branch.
- Requires threading `:resume_policy` into the non-template server-opts branch (it is currently dropped, `session.ex:115-127`): the deferral is only sound if the server actually sees the same policy the Session decided with. **This is a one-line scope addition to the approved spec — flag it in the PR/handoff.**
- Repair writes go to the store BEFORE the server starts; entries are re-read from the store afterwards so they carry store-minted `id`/`parent_id` links (constructing them locally would break `AgentMemory.from_entries/1`'s parent-chain walk).

### Steps

- [ ] **5.1 Write the failing recovery tests.** Create `test/agents/turn/tool_dispatch_recovery_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ToolDispatchRecoveryTest do
  @moduledoc """
  Fix 3 recovery paths: a crash between the `:tool_dispatch` persist and the
  batch's tool results leaves the store with a trailing unanswered `tool_use`.
  Rehydration must repair the transcript fail-closed (synthesized error results,
  never tool re-execution) before the next LLM call sees it.
  """
  use ExUnit.Case, async: false
  import Normandy.Test.Eventually

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.TranscriptIntegrity
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  # A response model the FSM finalizes on: no tool_calls → :completed.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Notify-instrumented fake tool: proves recovery NEVER re-executes tools.
  defmodule RecoveryTool do
    use Normandy.Schema

    schema do
      field(:name, :string)
      field(:notify, :any, default: nil)
    end
  end

  defimpl Normandy.Tools.BaseTool,
    for: Normandy.Agents.Turn.ToolDispatchRecoveryTest.RecoveryTool do
    def tool_name(t), do: t.name
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}

    def run(t) do
      if t.notify, do: send(t.notify, {:tool_ran, t.name})
      {:ok, "ran #{t.name}"}
    end
  end

  defp config_with_tools(notify) do
    tools = [%RecoveryTool{name: "weather", notify: notify}]

    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      initial_memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      tool_registry: Normandy.Tools.Registry.new(tools)
    }
  end

  # Seed the store exactly as a server that died mid-dispatch leaves it: user +
  # assistant tool_use entries persisted (Turn.Server appends with turn_id
  # "live"), tool results absent. Returns the assistant response for turn-state
  # seeding.
  defp seed_crashed_dispatch(store, sid, calls) do
    {:ok, _} =
      InMemory.append_entry(store, sid, %AgentMemory.Entry{
        turn_id: "live",
        role: "user",
        content: "please check the weather"
      })

    resp = %ToolCallResponse{content: nil, tool_calls: calls}

    {:ok, _} =
      InMemory.append_entry(store, sid, %AgentMemory.Entry{
        turn_id: "live",
        role: "assistant",
        content: resp
      })

    resp
  end

  # The state the :tool_dispatch entry persist (Fix 3, Task 2) leaves behind.
  defp crashed_dispatch_state(calls, resp) do
    %Turn.State{
      status: :tool_dispatch,
      pending_calls: calls,
      last_response: resp,
      iterations_left: 3,
      max_iterations: 3,
      response_model: %ToolCallResponse{},
      output_schema: %Resp{}
    }
  end

  defp final_llm_stub(content) do
    %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: content, tool_calls: nil} end
    }
  end

  test "pre-fix repair: dangling tool_use with NO turn_state gets synthesized error results" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    sid = "prefix-#{System.unique_integer([:positive])}"
    test_pid = self()

    call = %ToolCall{id: "c1", name: "weather", input: %{}}
    seed_crashed_dispatch(store, sid, [call])
    # No turn_state saved: pre-fix sessions and first-batch crashes look like this.
    assert :error = InMemory.load_turn_state(store, sid)

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn config, _s, _r ->
          send(test_pid, {:llm_saw, AgentMemory.entry_chain(config.memory)})
          %Resp{content: "recovered", tool_calls: nil}
        end
    }

    opts = [
      session_id: sid,
      config: config_with_tools(test_pid),
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      handlers: handlers
    ]

    assert {:ok, %Resp{content: "recovered"}} = Turn.Session.run(opts, "and now?")

    # The store transcript was repaired BEFORE the server started: the
    # synthesized error result directly answers the dangling tool_use, inside
    # the crashed turn, before the new user message.
    {:ok, entries} = InMemory.history(store, sid)
    assert TranscriptIntegrity.dangling_tool_calls(entries) == []
    assert Enum.map(entries, & &1.role) == ["user", "assistant", "tool", "user", "assistant"]

    repaired = Enum.at(entries, 2)
    assert %ToolResult{tool_call_id: "c1", is_error: true, output: %{interrupted: true}} =
             repaired.content

    # ...tagged with the dangling turn's id, not a fresh one.
    assert repaired.turn_id == "live"

    # The LLM never saw an unanswered tool_use...
    assert_receive {:llm_saw, chain}
    assert TranscriptIntegrity.dangling_tool_calls(chain) == []
    # ...and the interrupted tool was never re-executed (fail-closed).
    refute_received {:tool_ran, _}
  end

  test "crash mid-dispatch (lazy default): rehydration repairs before the next turn" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    sid = "lazy-crash-#{System.unique_integer([:positive])}"
    test_pid = self()

    call = %ToolCall{id: "c1", name: "weather", input: %{}}
    resp = seed_crashed_dispatch(store, sid, [call])
    :ok = InMemory.save_turn_state(store, sid, crashed_dispatch_state([call], resp))

    opts = [
      session_id: sid,
      config: config_with_tools(test_pid),
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      handlers: final_llm_stub("after crash")
      # no :resume_policy → :lazy (the default): no eager resume will ever
      # consume the pending state, so rehydration itself must repair.
    ]

    assert {:ok, %Resp{content: "after crash"}} = Turn.Session.run(opts, "and now?")

    {:ok, entries} = InMemory.history(store, sid)
    assert TranscriptIntegrity.dangling_tool_calls(entries) == []

    tool_results = for %{role: "tool", content: %ToolResult{} = r} <- entries, do: r
    assert [%ToolResult{tool_call_id: "c1", is_error: true}] = tool_results

    refute_received {:tool_ran, _}
  end

  test "crash mid-approval (lazy): rehydration also repairs an :awaiting_approval leftover" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    sid = "lazy-approval-#{System.unique_integer([:positive])}"
    test_pid = self()

    call = %ToolCall{id: "p1", name: "weather", input: %{}}
    resp = seed_crashed_dispatch(store, sid, [call])

    :ok =
      InMemory.save_turn_state(store, sid, %Turn.State{
        crashed_dispatch_state([call], resp)
        | status: :awaiting_approval,
          parked_calls: [call]
      })

    opts = [
      session_id: sid,
      config: config_with_tools(test_pid),
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      handlers: final_llm_stub("after approval crash")
    ]

    assert {:ok, %Resp{content: "after approval crash"}} = Turn.Session.run(opts, "and now?")

    {:ok, entries} = InMemory.history(store, sid)
    assert TranscriptIntegrity.dangling_tool_calls(entries) == []
    refute_received {:tool_ran, _}
  end

  test "crash mid-dispatch (eager): Turn.resume owns the repair — results appended exactly once" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    sid = "eager-crash-#{System.unique_integer([:positive])}"
    test_pid = self()

    call = %ToolCall{id: "c1", name: "weather", input: %{}}
    resp = seed_crashed_dispatch(store, sid, [call])
    :ok = InMemory.save_turn_state(store, sid, crashed_dispatch_state([call], resp))

    opts = [
      session_id: sid,
      config: config_with_tools(test_pid),
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      resume_policy: :eager,
      handlers: final_llm_stub("resumed")
    ]

    # Session defers the store-level repair (an eager resume will consume the
    # pending state); the server's :internal :resume then runs Turn.resume/1,
    # which synthesizes the batch through apply_tool_results — exactly once.
    # The postponed {:turn, "and now?"} runs after the resumed turn finalizes.
    assert {:ok, %Resp{content: "resumed"}} = Turn.Session.run(opts, "and now?")

    {:ok, entries} = InMemory.history(store, sid)
    assert TranscriptIntegrity.dangling_tool_calls(entries) == []

    results_for_c1 =
      for %{role: "tool", content: %ToolResult{tool_call_id: "c1"} = r} <- entries, do: r

    # Exactly ONE synthesized result: repaired by resume, NOT double-repaired
    # by rehydration.
    assert [%ToolResult{is_error: true, output: %{interrupted: true}}] = results_for_c1

    refute_received {:tool_ran, _}
  end
end
```

  Note: `import Normandy.Test.Eventually` and `wait_until/1` are used by Task 6's addition to this file; the import is included now so the file needs no header edits later.

- [ ] **5.2 Run and watch the four tests fail.**

```
mix format
mix test test/agents/turn/tool_dispatch_recovery_test.exs
```

Expected outcome: 4 failures.
  - Tests 1-3 fail at `assert TranscriptIntegrity.dangling_tool_calls(entries) == []` (and the roles assertion): no repair exists, so the dangling `tool_use` is still trailing the crashed turn. (The stubbed LLM ignores history, so `Session.run` itself succeeds — the store assertions are the RED signal.)
  - Test 4 (eager) fails the same way: the non-template branch of `rehydrate_and_start/1` currently DROPS `:resume_policy` (`session.ex:115-127`), so the server starts `:lazy`, never resumes, and nothing answers the batch.
  If a test fails on compilation or on `Session.run` instead, STOP and report.

- [ ] **5.3 Implement the repair.** In `lib/normandy/agents/turn/session.ex`:

  (a) Replace the alias block (lines 31-32):

```elixir
  alias Normandy.Agents.Turn.{Server, Supervisor}
  alias Normandy.Components.AgentMemory
```

  with:

```elixir
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.{Server, Supervisor}
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Components.TranscriptIntegrity
```

  (b) Replace the whole `rehydrate_and_start/1` function (lines 67-136) with:

```elixir
  defp rehydrate_and_start(opts) do
    {store_mod, store_handle} = Keyword.fetch!(opts, :store)
    sid = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    supervisor = Keyword.fetch!(opts, :supervisor)
    supervisor_mod = Keyword.get(opts, :supervisor_mod, Supervisor)
    template_provider = Keyword.get(opts, :template_provider)
    resume_policy = Keyword.get(opts, :resume_policy, :lazy)

    turn_state =
      case store_mod.load_turn_state(store_handle, sid) do
        {:ok, term} -> term
        :error -> nil
      end

    # `history/2` may return a contract-permitted `{:error, _}` on a genuine
    # store fault; propagate it as run/2's error tuple instead of crashing. The
    # transcript repair propagates its store faults the same way.
    with {:ok, entries} <- store_mod.history(store_handle, sid),
         {:ok, entries} <-
           repair_dangling_tool_calls(
             {store_mod, store_handle},
             sid,
             entries,
             turn_state,
             resume_policy
           ) do
      # `from_entries/1` rebuilds with `max_messages: nil`; restore the caller's
      # configured cap so passivation/rehydration doesn't silently uncap memory.
      rebuilt_memory = %{
        AgentMemory.from_entries(entries)
        | max_messages: config.memory.max_messages
      }

      config = %{config | memory: rebuilt_memory}

      server_opts =
        if template_provider do
          tmpl =
            Normandy.Agents.ConfigTemplate.from_config(config, template_id_of(opts, config))

          :ok = store_mod.save_config_template(store_handle, sid, tmpl)

          opts
          |> Keyword.take([
            :session_id,
            :store,
            :registry,
            :subscriber,
            :handlers,
            :approval_timeout_ms,
            :idle_timeout_ms,
            :template_provider
          ])
          |> Keyword.put(:resume_policy, resume_policy)
          |> Keyword.put(:turn_state, turn_state)
        else
          opts
          |> Keyword.take([
            :session_id,
            :store,
            :registry,
            :subscriber,
            :handlers,
            :approval_timeout_ms,
            :idle_timeout_ms
          ])
          |> Keyword.put(:config, config)
          # The repair-deferral decision above keys off resume_policy; the
          # server must see the SAME policy or an eager caller's deferred
          # repair would never be consumed (Fix 3).
          |> Keyword.put(:resume_policy, resume_policy)
          |> Keyword.put(:turn_state, turn_state)
        end

      {reg_mod, reg_handle} = Keyword.fetch!(opts, :registry)
      start_with_retry(supervisor_mod, supervisor, server_opts, reg_mod, reg_handle, sid)
    end
  end
```

  **Merge note:** if Plan 1 (Fix 1) already landed, the `ConfigTemplate.from_config(...)` call above will be the three-argument form ending in `resume_policy` — keep Plan 1's version; everything else is identical.

  (c) Add the private helpers below `start_with_retry/7` (before `already_started_pid/1`):

```elixir
  # ── Fix 3: transcript repair on rehydration ─────────────────────────────────
  #
  # A crash between persisting the assistant tool-call message and persisting
  # the batch's tool results leaves the store with a trailing unanswered
  # `tool_use`; replayed verbatim, the next LLM call gets a provider 400. Repair
  # here — append one synthesized error tool_result per dangling call, persisted
  # to the store BEFORE the server starts — unless an eager resume will consume
  # the persisted pending state, in which case `Turn.resume/1` owns the repair
  # (repairing in both places would double-answer the batch). Fail-closed:
  # tools are never re-executed on resume, under any path.
  defp repair_dangling_tool_calls({store_mod, store_handle}, sid, entries, turn_state, policy) do
    dangling = TranscriptIntegrity.dangling_tool_calls(entries)

    cond do
      dangling == [] ->
        {:ok, entries}

      policy == :eager and covers_dangling?(turn_state, dangling) ->
        {:ok, entries}

      true ->
        turn_id = trailing_assistant_turn_id(entries)

        appended =
          dangling
          |> TranscriptIntegrity.synthesized_error_results()
          |> Enum.reduce_while(:ok, fn result, :ok ->
            entry = %AgentMemory.Entry{turn_id: turn_id, role: "tool", content: result}

            case store_mod.append_entry(store_handle, sid, entry) do
              {:ok, _id} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, {:repair_failed, reason}}}
            end
          end)

        # Re-read so the repaired entries carry store-minted ids/parent links
        # (locally-built entries would break from_entries/1's parent-chain walk).
        with :ok <- appended, do: store_mod.history(store_handle, sid)
    end
  end

  # The persisted state can answer the dangling calls itself only when its
  # pending batch covers every dangling id AND the shell will actually resolve
  # it: `:tool_dispatch` resumes via synthesized results (Turn.resume/1);
  # `:awaiting_approval` resolves via approval decisions or expiry. Any other
  # shape (nil, terminal, partial coverage — pre-fix sessions, first-batch
  # crashes) cannot, so rehydration must repair.
  defp covers_dangling?(%Turn.State{status: status, pending_calls: calls}, dangling)
       when status in [:tool_dispatch, :awaiting_approval] and is_list(calls) do
    pending_ids = MapSet.new(calls, &call_id/1)
    Enum.all?(dangling, fn %ToolCall{id: id} -> MapSet.member?(pending_ids, id) end)
  end

  defp covers_dangling?(_turn_state, _dangling), do: false

  defp call_id(%{id: id}), do: id
  defp call_id(_), do: nil

  # Synthesized results belong to the dangling turn, not a fresh one. The
  # trailing assistant entry (the dangling tool_use) is the last assistant in
  # the transcript whenever dangling calls exist.
  defp trailing_assistant_turn_id(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(&(&1.role == "assistant"))
    |> case do
      %AgentMemory.Entry{turn_id: turn_id} -> turn_id
      nil -> "live"
    end
  end
```

- [ ] **5.4 Run and watch all four pass, then the full suite.**

```
mix format
mix test test/agents/turn/tool_dispatch_recovery_test.exs
mix test
```

Expected outcome: `4 tests, 0 failures` in the recovery file; 0 failures overall. Why existing session/server suites survive: every existing test seeds either clean histories or `:steering` states — `dangling_tool_calls/1` returns `[]` and the repair is a no-op; the extra `:resume_policy` in non-template server opts defaults to `:lazy`, matching the server's previous default.

```
VERIFY: Ran mix test — Result: [PASS/FAIL/DID NOT RUN]
```

- [ ] **5.5 Commit.**

```
git add lib/normandy/agents/turn/session.ex
git add test/agents/turn/tool_dispatch_recovery_test.exs
git commit -m "feat(turn): repair dangling tool_use transcripts on session rehydration"
```

---

## Task 6: Server-direct crash-mid-dispatch integration verification

**Files:**
- Modify `test/agents/turn/tool_dispatch_recovery_test.exs` (add one test)

**Interfaces:** consumes only public seams already built: `Turn.Server.start_link/1` with `:config` + `resume_policy: :eager` (server init honors opts policy when `:config` is present, `server.ex:75-79`), `InMemory.load_turn_state/2`, `AgentMemory.from_entries/1`, `TranscriptIntegrity.dangling_tool_calls/1`.

**This test is expected GREEN on arrival** — it is the acceptance test for the composition of Task 4 (resume clause) with the Server shell, independent of the Session threading added in Task 5. It exists because no other test drives the Server's `:internal :resume` over a `:tool_dispatch` state with a real store transcript. If it fails, do NOT patch the test — use superpowers:systematic-debugging: one of Tasks 2/4 is wrong.

### Steps

- [ ] **6.1 Add the test** at the end of `Normandy.Agents.Turn.ToolDispatchRecoveryTest` (before the final `end`):

```elixir
  test "Server-direct eager resume of a persisted :tool_dispatch state repairs and finalizes" do
    store = InMemory.new()
    reg = Native.new()
    sid = "direct-eager-#{System.unique_integer([:positive])}"
    test_pid = self()

    call = %ToolCall{id: "c1", name: "weather", input: %{}}
    resp = seed_crashed_dispatch(store, sid, [call])

    :ok =
      InMemory.save_turn_state(store, sid, %Turn.State{
        crashed_dispatch_state([call], resp)
        | iterations_left: 2,
          max_iterations: 5
      })

    # Rebuild memory from the (unrepaired) store history, as a rehydrating
    # shell would, so the resumed turn's appends land on the real transcript.
    {:ok, entries} = InMemory.history(store, sid)
    config = %{config_with_tools(test_pid) | memory: AgentMemory.from_entries(entries)}

    {:ok, _pid} =
      Turn.Server.start_link(
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, reg},
        resume_policy: :eager,
        handlers: final_llm_stub("recovered")
      )

    # No caller: the resumed turn finalizes silently. Poll for the terminal state.
    assert wait_until(fn ->
             match?({:ok, %Turn.State{status: :stopped}}, InMemory.load_turn_state(store, sid))
           end)

    {:ok, repaired} = InMemory.history(store, sid)
    assert TranscriptIntegrity.dangling_tool_calls(repaired) == []
    assert Enum.map(repaired, & &1.role) == ["user", "assistant", "tool", "assistant"]

    assert [%ToolResult{tool_call_id: "c1", is_error: true}] =
             for(%{role: "tool", content: %ToolResult{} = r} <- repaired, do: r)

    refute_received {:tool_ran, _}
  end
```

- [ ] **6.2 Run it (expected pass), then the full suite.**

```
mix format
mix test test/agents/turn/tool_dispatch_recovery_test.exs
mix test
```

Expected outcome: `5 tests, 0 failures` in the recovery file; 0 failures overall.

```
VERIFY: Ran mix test — Result: [PASS/FAIL/DID NOT RUN]
```

- [ ] **6.3 Commit.**

```
git add test/agents/turn/tool_dispatch_recovery_test.exs
git commit -m "test(turn): server-direct eager resume coverage for crash-mid-dispatch recovery"
```

---

## Task 7: Full-suite gate and handoff

**Files:** none modified — verification only.

### Steps

- [ ] **7.1 Full verification, in repo-convention order.**

```
mix format
mix test
mix dialyzer
```

Expected outcome: `mix format` produces no diff (run `git status` to confirm — if it reformatted anything, the offending task skipped its format step; re-run that file's tests and amend the task's commit); `mix test` reports 0 failures; `mix dialyzer` reports no errors (the CI gate was re-enabled in commit `cf8fd08` — if the local PLT is not built, `mix dialyzer` will build it first; let it).

```
VERIFY: Ran mix test — Result: [PASS/FAIL/DID NOT RUN]
VERIFY: Ran mix dialyzer — Result: [PASS/FAIL/DID NOT RUN]
```

- [ ] **7.2 Spec-coverage checklist (confirm each maps to a landed artifact).**

| Spec requirement (Fix 3) | Artifact |
|---|---|
| `:tool_dispatch` transition emits `[append, {:persist, s'}, dispatch]`, `s'` carries `pending_calls` + status | Task 2, `turn.ex` + `turn_test.exs` ordering test |
| All three interpreters handle `{:persist, _}` (Driver/Inline no-op, Server writes) | Task 2.4 verification (driver.ex:84-86, inline.ex:96-98, server.ex:294-298) |
| `apply_tool_results/2` set-compares ids; mismatch → `{:fail, {:incomplete_batch, %{missing: [...], unexpected: [...]}}}`, state `:failed` | Task 3 |
| `Turn.resume/1` on `:tool_dispatch` synthesizes via `TranscriptIntegrity`, feeds normal `apply_tool_results`; catch-all no longer forces `:failed` for it | Task 4 |
| Rehydration repair in `Session.rehydrate_and_start/1`: dangling + no usable pending state → synthesized error entries appended AND persisted before the server starts | Task 5 |
| Fail-closed guarantee: tools never re-execute on resume | `refute_received {:tool_ran, _}` in all five recovery tests; no `{:dispatch_tools, _}` in resume effects (Task 4 test) |
| `TranscriptIntegrity` pinned interface for Plan 3 | Task 1 (`dangling_tool_calls/1`, `synthesized_error_results/2`; `snap_cut/2` noted in moduledoc, NOT implemented) |

- [ ] **7.3 Handoff notes for the PR body / reviewer.**
  - Scope addition vs the approved spec, deliberate and flagged: `:resume_policy` is now threaded through the **non-template** server-opts branch of `Session.rehydrate_and_start/1` (it was silently dropped). Without it, the Session's repair-deferral decision (defer when eager) and the server's actual policy could disagree, leaving an eager session's transcript unrepaired forever.
  - Interpretation made precise: "no usable persisted pending state" = not (`resume_policy == :eager` AND persisted `:tool_dispatch`/`:awaiting_approval` whose `pending_calls` cover every dangling id). Rationale in `session.ex` comments and Task 5's interface notes; the lazy default repairs at rehydration, eager defers to `Turn.resume/1`.
  - Behavior change worth calling out: `step/2` on a mismatched tool batch now fails the turn with `{:incomplete_batch, _}` instead of silently appending. Custom shells/stubs that fabricate results must emit one `%ToolResult{tool_call_id: ...}` per pending call (two test stubs in-repo needed exactly this fix).

## Known limitations (documented, not blocking)

- The rehydration repair reads only the **trailing** batch (`dangling_tool_calls/1`). Unanswered `tool_use` deeper in history can only be produced by truncation defects — Plan 3 (Fix 4) owns those via `snap_cut/2`.
- Store-level repair and the eager-deferral decision are per-rehydration; a store shared by concurrently rehydrating nodes is a split-brain concern owned by Plan 5 (Fix 6 fencing), not this plan.
- `Turn.Inline` and `Turn.Driver` shells have no store, so crash-mid-dispatch durability does not apply to them; they participate only via the (no-op) `{:persist, _}` effect and the completeness assertion.
