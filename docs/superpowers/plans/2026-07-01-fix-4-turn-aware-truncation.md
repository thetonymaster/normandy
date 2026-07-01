# Fix 4 — Turn-Aware Truncation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all three truncation paths — `AgentMemory.enforce_max_messages` (the `max_messages` cap), `Context.WindowManager.split_to_fit/2` (token-budget truncation), and `Context.Summarizer`'s count-based split — cut only on turn boundaries, so a surviving history can never start with an orphaned `tool_result` or sever a `tool_use` from its results. As an in-scope side effect, the window manager and summarizer rebuild memory from entries instead of serialized history maps, fixing struct-loss-on-truncation.

**Architecture:** The pairing invariant is owned by `Normandy.Components.TranscriptIntegrity` (created by Plan 2). This plan adds one function to it: `snap_cut(entries, desired_kept_count)` — given chronologically ordered entries and a desired kept count (newest N), extend the kept set backward until the oldest kept entry begins a `turn_id`. Because `BaseAgent.prepare_input/2` mints one `turn_id` per user turn (`base_agent.ex:536`) and every tool-loop message (assistant `ToolCallResponse` with `tool_use`, `"tool"`-role `ToolResult`s, final assistant message) is appended under that same `turn_id`, "cut only on turn boundaries" is exactly "never orphan a tool pairing."

- **Stage 1** — `enforce_max_messages` (`agent_memory.ex:235-258`) snaps its cut with `snap_cut/2`. The cap's meaning changes from "exactly the newest N entries" to "**at least** N entries, rounded up to a whole turn." Documented edge case: a single turn longer than `max_messages` is kept whole — an orphaned transcript is never the right trade.
- **Stage 2** — a new `AgentMemory.history_entries/1` returns the active branch as `Entry` structs with `turn_id` and `role` intact (`history/1`'s serialized shape is UNTOUCHED — adapters depend on it). `WindowManager.split_to_fit/2` computes its token-budget count as before, then snaps it with `snap_cut/2`; the summarizer's `keep_recent` split point snaps the same way. `rebuild_memory/2` (window manager) and `rebuild_memory_with_summary/4` (summarizer) rebuild via `AgentMemory.from_entries/1` from the surviving `Entry` structs — turn ids, roles, and struct content survive truncation (the old map-based rebuild permanently downgraded struct content to serialized JSON/blocks and collapsed every survivor into the current turn).
- **Shared regression net** — a generator producing multi-iteration tool-loop conversations, run through all three truncation paths, asserting: (1) no surviving history starts with role `"tool"`; (2) every surviving `tool_result`'s `tool_use` is in the surviving history; (3) every surviving `tool_use` has all its results.

**Documented behavior changes** (all intended, per the approved spec):
1. `max_messages` becomes "at least N, whole turns" (a single oversized turn is kept whole).
2. `split_to_fit`'s token budget rounds **up** to a turn boundary — the kept suffix may exceed `target_tokens` by up to one turn.
3. The summarizer's summary entry gets its **own** fresh `turn_id` (previously the summary and all kept messages were collapsed into the current turn), so `delete_turn/2` on the active turn no longer deletes the summary.
4. Rebuilt memories restore `max_messages` without re-running cap enforcement during the rebuild; the cap re-applies (turn-aware) on the next `add_message/3`.
5. Struct content survives truncation/summarization instead of being downgraded to serialized history content.

**Tech Stack:** Elixir, ExUnit, Poison, `elixir_uuid`. No new dependencies.

**Reference:** `docs/superpowers/specs/2026-07-01-critical-fixes-design.md` — "Fix 4", "Decisions", "Plan packaging and sequencing".

## Global Constraints

- **HARD DEPENDENCY: Plan 2 must be complete first.** This plan consumes `Normandy.Components.TranscriptIntegrity` (with `dangling_tool_calls/1` and `synthesized_error_results/2`), introduced by Plan 2 (`docs/superpowers/plans/2026-07-01-fix-3-tool-dispatch-persistence-and-repair.md`). Task 0 verifies this; if the module is missing, STOP and report — do not create it here.
- **`history/1` shape frozen.** `AgentMemory.history/1` keeps returning `[%{role: String.t(), content: String.t() | list()}]` with `BaseIOSchema.to_json/1`-serialized content. Adapters depend on it.
- **Public signatures frozen:** `WindowManager.ensure_within_limit/2`, `truncate_conversation/2`, `within_limit?/2`, `Summarizer.compress_conversation/3`, `summarize_messages/4` keep their signatures and success/error shapes. `summarize_messages/4` must keep accepting plain `%{role:, content:}` maps (its tests pass maps); it additionally receives `Entry` structs from the compress path — both respond to `.role`/`.content`.
- **Existing tests that build single-turn memories and assert truncation happens must be updated, not deleted** — under turn-aware semantics a single-turn conversation is kept whole, so those builders mint one turn per message via `AgentMemory.initialize_turn/1` (preserving each test's intent). The full list is in Tasks 2, 4, and 5; no other tests may be modified.
- **Full suite green at every checkpoint.** Baseline on main before Plans 2/3: `71 doctests, 26 properties, 1432 tests, 0 failures (128 excluded)`. Plan 2 will have raised the totals — record YOUR observed baseline in Task 0 and compare against it. The log line `[error] normandy agent exception` is expected test output, not a failure.
- **Run `mix format` before every test run** (project CLAUDE.md). If any test fails, it must be fixed — even tests we were not working on.
- **Git discipline:** never `git add .` — add files individually. Use each task's commit message verbatim. No AI authorship attribution in commits.
- **Do not touch** `Turn.step/2` effects, the three Turn interpreters, `estimate_tokens/1` heuristics, or `Behaviours.Compactor.WindowManager` (it delegates to `ensure_within_limit/2` and needs no change).

---

### Task 0: Preflight — verify the Plan 2 dependency and record the baseline

**Files:** none modified.

- [ ] **Step 1: Verify `TranscriptIntegrity` exists with the Plan 2 interface**

Run:

```bash
grep -n "def dangling_tool_calls\|def synthesized_error_results" lib/normandy/components/transcript_integrity.ex
```

Expected: both function heads found in `lib/normandy/components/transcript_integrity.ex`.
If the file or either function is missing: **STOP. Plan 2 (`2026-07-01-fix-3-tool-dispatch-persistence-and-repair.md`) has not landed. Report to Q and do not proceed.**

- [ ] **Step 2: Record the green baseline**

Run: `mix format --check-formatted && mix test`
Expected: 0 failures. Write down the exact totals line (doctests/properties/tests/excluded) — every later "full suite" step compares against it.

---

### Task 1: `TranscriptIntegrity.snap_cut/2`

**Files:**
- Modify: `lib/normandy/components/transcript_integrity.ex` (append one public function)
- Create: `test/components/transcript_integrity_snap_cut_test.exs`

**Interfaces:**
- Produces: `TranscriptIntegrity.snap_cut([Entry.t()], integer()) :: [Entry.t()]` — chronological entries in, chronological suffix out; the suffix's oldest entry begins a `turn_id`; `length(result) >= desired_kept_count` whenever truncation occurs (rounded up to a whole turn); `<= 0` → `[]`; `>= length(entries)` → all entries.
- Consumes: `Normandy.Components.AgentMemory.Entry` (`turn_id` field only — entries of one turn are contiguous in a chain, which `chunk_by/2` relies on).

- [ ] **Step 1: Write the failing unit test**

Create `test/components/transcript_integrity_snap_cut_test.exs`:

```elixir
defmodule Normandy.Components.TranscriptIntegritySnapCutTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.TranscriptIntegrity

  defp e(id, turn) do
    %Entry{id: id, parent_id: nil, turn_id: turn, role: "user", content: %{}}
  end

  test "keeps everything when the desired count covers all entries" do
    entries = [e("1", "A"), e("2", "A"), e("3", "B")]
    assert TranscriptIntegrity.snap_cut(entries, 3) == entries
    assert TranscriptIntegrity.snap_cut(entries, 99) == entries
  end

  test "returns [] for a non-positive desired count or empty input" do
    entries = [e("1", "A")]
    assert TranscriptIntegrity.snap_cut(entries, 0) == []
    assert TranscriptIntegrity.snap_cut(entries, -1) == []
    assert TranscriptIntegrity.snap_cut([], 5) == []
  end

  test "a cut landing exactly on a turn boundary keeps exactly the desired count" do
    entries = [e("1", "A"), e("2", "A"), e("3", "B"), e("4", "B")]
    assert TranscriptIntegrity.snap_cut(entries, 2) == [e("3", "B"), e("4", "B")]
  end

  test "rounds a mid-turn cut up to the whole turn" do
    entries = [e("1", "A"), e("2", "A"), e("3", "B"), e("4", "B"), e("5", "B")]
    # Desired newest 2 starts mid-turn-B -> extended to all of turn B.
    assert TranscriptIntegrity.snap_cut(entries, 2) == [e("3", "B"), e("4", "B"), e("5", "B")]
    # Desired newest 4 starts mid-turn-A -> extended to the full list.
    assert TranscriptIntegrity.snap_cut(entries, 4) == entries
  end

  test "a single turn longer than the desired count is kept whole (never orphaned)" do
    entries = for i <- 1..6, do: e("#{i}", "only-turn")
    assert TranscriptIntegrity.snap_cut(entries, 2) == entries
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/components/transcript_integrity_snap_cut_test.exs`
Expected: FAIL — `TranscriptIntegrity.snap_cut/2` is undefined.

- [ ] **Step 3: Implement `snap_cut/2`**

In `lib/normandy/components/transcript_integrity.ex`, ensure the module aliases `Normandy.Components.AgentMemory.Entry` (Plan 2 very likely already does; add the alias if not), then append:

```elixir
  @doc """
  Snap a truncation cut to a turn boundary.

  Given `entries` in chronological order (oldest -> newest) and a desired kept
  count (the newest `desired_kept_count` entries), returns the kept suffix
  extended backward until its oldest entry begins a `turn_id` — whole turns
  only. A cut point is valid only on a turn boundary: the oldest surviving
  entry must be the first entry of its turn.

  Edge cases:
  - `desired_kept_count <= 0` -> `[]` (an empty transcript has no orphans)
  - `desired_kept_count >= length(entries)` -> all entries
  - a single turn longer than `desired_kept_count` is kept whole — an
    orphaned transcript is never the right trade
  """
  @spec snap_cut([Entry.t()], integer()) :: [Entry.t()]
  def snap_cut(entries, desired_kept_count) when is_list(entries) and desired_kept_count <= 0,
    do: []

  def snap_cut(entries, desired_kept_count) when is_list(entries) do
    if desired_kept_count >= length(entries) do
      entries
    else
      entries
      |> Enum.chunk_by(& &1.turn_id)
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn turn_entries, {kept, count} ->
        if count >= desired_kept_count do
          {:halt, {kept, count}}
        else
          {:cont, {turn_entries ++ kept, count + length(turn_entries)}}
        end
      end)
      |> elem(0)
    end
  end
```

(`chunk_by/2` groups contiguous same-`turn_id` runs; walking chunks newest-first and prepending keeps the result chronological.)

- [ ] **Step 4: Run the unit test**

Run: `mix format && mix test test/components/transcript_integrity_snap_cut_test.exs`
Expected: PASS (5 tests, 0 failures).

- [ ] **Step 5: Run the whole suite**

Run: `mix test`
Expected: baseline totals + 5 new tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/components/transcript_integrity.ex test/components/transcript_integrity_snap_cut_test.exs
git commit -m "feat(components): add TranscriptIntegrity.snap_cut/2 for turn-boundary truncation"
```

---

### Task 2: Stage 1 — `enforce_max_messages` snaps to turn boundaries

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (`enforce_max_messages/1`, ~lines 235-258; add one alias)
- Modify: `test/components/agent_memory_test.exs` (update ONE existing test; add three new tests)

**Interfaces:**
- Produces: no signature changes. `enforce_max_messages/1` (private, runs on every `add_message/3`) now keeps at least `max_messages` entries rounded up to a whole turn; `max_messages: nil` and `max_messages: 0` clauses unchanged.
- Consumes: `TranscriptIntegrity.snap_cut/2` (Task 1).

- [ ] **Step 1: Update the one existing test whose builder shares a single turn**

In `test/components/agent_memory_test.exs`, the test `"max_messages overflow keeps only the newest entries"` (~line 57) adds two messages under ONE `turn_id` (`add_message/3` only auto-mints a turn when `current_turn_id` is nil) — under turn-aware semantics both would be kept. Replace it with (same intent, one turn per message):

```elixir
  test "max_messages overflow keeps only the newest whole turns" do
    memory = AgentMemory.new_memory(1)

    memory =
      memory
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("main", %{hello: "goodbye"})

    memory =
      memory
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("secondary", %{goodbye: "hello"})

    assert AgentMemory.count_messages(memory) == 1
    assert [%Message{role: "secondary"}] = AgentMemory.messages(memory)
  end
```

- [ ] **Step 2: Add the new failing tests**

Append to `test/components/agent_memory_test.exs` (top level of the module, alongside the other tests):

```elixir
  test "max_messages rounds up to a whole turn (never cuts mid-turn)" do
    # Turn A: 2 entries; turn B: 3 entries; cap 2. The newest 2 entries are a
    # partial slice of turn B, so the cap must keep all 3 of turn B.
    memory =
      AgentMemory.new_memory(2)
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", %{q: "a1"})
      |> AgentMemory.add_message("assistant", %{a: "a2"})

    memory = AgentMemory.initialize_turn(memory)
    turn_b = AgentMemory.get_current_turn_id(memory)

    memory =
      memory
      |> AgentMemory.add_message("user", %{q: "b1"})
      |> AgentMemory.add_message("assistant", %{a: "b2"})
      |> AgentMemory.add_message("assistant", %{a: "b3"})

    assert AgentMemory.count_messages(memory) == 3
    assert Enum.all?(AgentMemory.messages(memory), &(&1.turn_id == turn_b))

    # The surviving root is re-rooted (no dangling parent link).
    [oldest | _] = AgentMemory.entry_chain(memory)
    assert oldest.parent_id == nil
  end

  test "a single turn longer than max_messages is kept whole" do
    memory =
      Enum.reduce(
        1..5,
        AgentMemory.new_memory(2) |> AgentMemory.initialize_turn(),
        fn i, mem -> AgentMemory.add_message(mem, "assistant", %{step: i}) end
      )

    assert AgentMemory.count_messages(memory) == 5
  end

  test "whole old turns are dropped once the cap is exceeded" do
    # One turn per entry: the cap behaves exactly as the old entry cap did.
    memory =
      Enum.reduce(1..6, AgentMemory.new_memory(2), fn i, mem ->
        mem
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", %{i: i})
      end)

    assert AgentMemory.count_messages(memory) == 2
    assert Enum.map(AgentMemory.messages(memory), & &1.content) == [%{i: 5}, %{i: 6}]
  end
```

- [ ] **Step 3: Run to verify the new tests fail**

Run: `mix format && mix test test/components/agent_memory_test.exs`
Expected: FAIL — `"max_messages rounds up to a whole turn"` asserts count 3 but gets 2 (old code cuts mid-turn-B), and `"a single turn longer than max_messages is kept whole"` asserts 5 but gets 2. `"whole old turns are dropped..."` and the Step 1 rewrite pass even against old code (per-entry turns).

- [ ] **Step 4: Implement**

In `lib/normandy/components/agent_memory.ex`:

(a) Add to the alias block at the top (after `alias Normandy.Components.BaseIOSchema`):

```elixir
  alias Normandy.Components.TranscriptIntegrity
```

(b) Replace the third `enforce_max_messages/1` clause (the `%__MODULE__{max_messages: max}` one, ~lines 241-258; the `nil` and `0` clauses stay) with:

```elixir
  # Turn-aware cap: keep at least `max` entries, rounded up to a whole turn
  # (TranscriptIntegrity.snap_cut/2), so the cap can never orphan a
  # tool_result from its tool_use mid-tool-loop. Edge case: a single turn
  # longer than `max` is kept whole — an orphaned transcript is never the
  # right trade.
  defp enforce_max_messages(%__MODULE__{max_messages: max} = memory) do
    chronological = memory |> chain_newest_first() |> Enum.reverse()

    if length(chronological) <= max do
      memory
    else
      kept = TranscriptIntegrity.snap_cut(chronological, max)
      dropped = Enum.take(chronological, length(chronological) - length(kept))

      case dropped do
        [] ->
          # Snapping absorbed the whole chain (single oversized turn): keep it.
          memory

        _ ->
          oldest_kept = List.first(kept)

          entries =
            dropped
            |> Enum.reduce(memory.entries, fn %Entry{id: id}, acc -> Map.delete(acc, id) end)
            |> Map.update!(oldest_kept.id, fn entry -> %{entry | parent_id: nil} end)

          %{memory | entries: entries}
      end
    end
  end
```

(c) In the moduledoc, append one sentence to the end:

```
  The `max_messages` cap is turn-aware: it keeps at least that many entries,
  rounded up to a whole turn, and never splits a turn (see
  `Normandy.Components.TranscriptIntegrity.snap_cut/2`).
```

- [ ] **Step 5: Run the file, then the whole suite**

Run: `mix format && mix test test/components/agent_memory_test.exs`
Expected: PASS.
Run: `mix test`
Expected: baseline + 5 (Task 1) + 3 new, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/components/agent_memory.ex test/components/agent_memory_test.exs
git commit -m "feat(memory): snap max_messages cap to turn boundaries via TranscriptIntegrity"
```

---

### Task 3: `AgentMemory.history_entries/1`

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (one new public function)
- Modify: `test/components/agent_memory_test.exs` (one new test)

**Interfaces:**
- Produces: `AgentMemory.history_entries(t()) :: [Entry.t()]` — the active branch, chronological, as full `Entry` structs (`turn_id`, `role`, raw `content` intact). This is the truncation/compaction-facing view; `history/1` stays byte-identical.
- Consumes: `entry_chain/1` (already exists and returns exactly this — `history_entries/1` is the stable, intent-named accessor Stage 2 code and downstream plans depend on).

- [ ] **Step 1: Write the failing test**

Append to `test/components/agent_memory_test.exs`:

```elixir
  test "history_entries/1 returns Entry structs with turn_id, role, and content intact" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    turn_a = AgentMemory.get_current_turn_id(memory)
    content = %IOTest{test_field: "hello"}
    memory = AgentMemory.add_message(memory, "user", content)

    memory = AgentMemory.initialize_turn(memory)
    turn_b = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "assistant", %{"type" => "raw"})

    assert [
             %Entry{turn_id: ^turn_a, role: "user", content: ^content},
             %Entry{turn_id: ^turn_b, role: "assistant", content: %{"type" => "raw"}}
           ] = AgentMemory.history_entries(memory)

    # history/1 shape is untouched — adapters depend on it.
    assert AgentMemory.history(memory) == [
             %{role: "user", content: "{\"test_field\":\"hello\"}"},
             %{role: "assistant", content: "{\"type\":\"raw\"}"}
           ]
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/components/agent_memory_test.exs`
Expected: FAIL — `AgentMemory.history_entries/1` is undefined.

- [ ] **Step 3: Implement**

In `lib/normandy/components/agent_memory.ex`, directly below `history/1`:

```elixir
  @doc """
  The active branch as full `Entry` structs, chronological (oldest -> newest),
  with `turn_id`, `role`, and raw `content` intact.

  This is the truncation/compaction-facing view: unlike `history/1` (whose
  serialized `%{role, content}` shape adapters depend on, and which stays
  untouched), `history_entries/1` preserves the information needed to cut on
  turn boundaries and to rebuild memory without downgrading struct content.
  """
  @spec history_entries(t()) :: [Entry.t()]
  def history_entries(%__MODULE__{} = memory), do: entry_chain(memory)
```

- [ ] **Step 4: Run the file, then the whole suite**

Run: `mix format && mix test test/components/agent_memory_test.exs`
Expected: PASS.
Run: `mix test`
Expected: previous totals + 1, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/components/agent_memory.ex test/components/agent_memory_test.exs
git commit -m "feat(memory): add history_entries/1 entry-level history accessor"
```

---

### Task 4: Stage 2a — WindowManager snaps `split_to_fit/2` and rebuilds from entries

**Files:**
- Modify: `lib/normandy/context/window_manager.ex` (`truncate_oldest_first/2`, `split_to_fit/2`, `rebuild_memory/2`, ~lines 264-368; three new aliases; one new private helper)
- Modify: `test/context/window_manager_test.exs` (update four existing builders; add three aliases and one new test)
- Modify: `test/behaviours/compactor_test.exs` (update the `mem_with/1` helper)

**Interfaces:**
- Produces: no public signature changes. `split_to_fit/2` now takes/returns `[Entry.t()]` (it is private); its token budget becomes "newest entries fitting `target_tokens`, rounded UP to a whole turn". `rebuild_memory/2` rebuilds via `AgentMemory.from_entries/1`, preserving `max_messages` and `current_turn_id`, re-rooting the oldest survivor (`parent_id: nil`), and NOT re-running cap enforcement.
- Consumes: `AgentMemory.history_entries/1` (Task 3), `TranscriptIntegrity.snap_cut/2` (Task 1), `BaseIOSchema.to_json/1` (so per-entry token estimates match `estimate_conversation_tokens/1`'s serialized view exactly).
- NOT touched: `estimate_conversation_tokens/1`, `estimate_messages_for_tokens/2`, `truncate_with_summary/2`, `within_limit?/2`, `Behaviours.Compactor.WindowManager`.

- [ ] **Step 1: Update the existing single-turn test builders (suite must stay green)**

These tests build every message under ONE `turn_id` (`add_message/3` only mints a turn when `current_turn_id` is nil). Under turn-aware truncation a single-turn conversation is kept whole, so mint one turn per message — which preserves each test's intent and passes against BOTH old and new code.

(a) `test/context/window_manager_test.exs`, `"truncates when over limit"` (describe `ensure_within_limit/2`) — replace the memory builder with:

```elixir
      memory =
        Enum.reduce(1..20, AgentMemory.new_memory(), fn i, mem ->
          mem
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", "Message #{i}")
        end)
```

(b) `"removes oldest messages first"` (describe `truncate_conversation/2 with :oldest_first strategy`) — replace the memory builder with three user/assistant turns:

```elixir
      memory =
        AgentMemory.new_memory()
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", "First message that is quite long")
        |> AgentMemory.add_message("assistant", "First response that is quite long")
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", "Second message that is quite long")
        |> AgentMemory.add_message("assistant", "Second response that is quite long")
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message("user", "Third message that is quite long")
        |> AgentMemory.add_message("assistant", "Third response that is quite long")
```

(c) `"keeps most recent messages"` (describe `... :sliding_window strategy`) — replace the builder with:

```elixir
      memory =
        Enum.reduce(1..10, AgentMemory.new_memory(), fn i, mem ->
          mem
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", "Message number #{i} with some content here")
        end)
```

(d) `"falls back to oldest_first when no client available"` (describe `... :summarize strategy`) — replace the builder with:

```elixir
      memory =
        Enum.reduce(1..10, AgentMemory.new_memory(), fn i, mem ->
          mem
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", "Message #{i} with lots of content here")
        end)
```

Leave `"summarizes old messages when client is available"` alone — it exercises the summarizer, which changes in Task 5.

(e) `test/behaviours/compactor_test.exs` — replace `mem_with/1` (inside the `"WindowManager impl"` describe) with:

```elixir
    defp mem_with(messages) do
      Enum.reduce(messages, AgentMemory.new_memory(nil), fn {role, content}, m ->
        m
        |> AgentMemory.initialize_turn()
        |> AgentMemory.add_message(role, content)
      end)
    end
```

Run: `mix format && mix test test/context/window_manager_test.exs test/behaviours/compactor_test.exs`
Expected: PASS — per-message turns do not change old (entry-blind) truncation behavior.

- [ ] **Step 2: Add the failing turn-aware test**

In `test/context/window_manager_test.exs`, add to the alias block at the top:

```elixir
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
```

Then append a new describe block:

```elixir
  describe "turn-aware truncation (oldest_first)" do
    test "cuts only on turn boundaries and preserves struct content" do
      # Three turns, five entries each: user + 2 x (assistant tool_use + tool result).
      memory =
        Enum.reduce(1..3, AgentMemory.new_memory(), fn t, mem ->
          mem = AgentMemory.initialize_turn(mem)
          mem = AgentMemory.add_message(mem, "user", "question #{t} padded for tokens")

          Enum.reduce(1..2, mem, fn i, m ->
            call_id = "call_#{t}_#{i}"

            m
            |> AgentMemory.add_message("assistant", %ToolCallResponse{
              tool_calls: [%ToolCall{id: call_id, name: "lookup", input: %{"k" => "#{t}-#{i}"}}]
            })
            |> AgentMemory.add_message("tool", %ToolResult{
              tool_call_id: call_id,
              output: %{"v" => "result #{t}-#{i}"}
            })
          end)
        end)

      agent = %{memory: memory, config: %{}}

      # A budget the old entry-blind split satisfied mid-turn (orphaning a
      # tool_result); the snapped split must keep whole turns only.
      manager = WindowManager.new(max_tokens: 260, reserved_tokens: 20, strategy: :oldest_first)

      {:ok, truncated} = WindowManager.truncate_conversation(agent, manager)

      entries = AgentMemory.history_entries(truncated.memory)

      assert entries != []
      assert length(entries) < 15
      assert rem(length(entries), 5) == 0, "cut mid-turn: #{length(entries)} entries survive"
      assert hd(entries).role == "user"

      # Struct content survives truncation — no serialized-history downgrade.
      assert Enum.all?(entries, fn e ->
               match?(%ToolCallResponse{}, e.content) or match?(%ToolResult{}, e.content) or
                 is_binary(e.content)
             end)
    end
  end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix format && mix test test/context/window_manager_test.exs`
Expected: FAIL — the new test only. The old split keeps a mid-turn count (6-9 entries; `rem(_, 5) != 0`), the surviving head is a `"tool"`-role orphan, and old `rebuild_memory/2` downgraded content to serialized block lists (the `Enum.all?` struct check fails). Everything else passes.

- [ ] **Step 4: Implement**

In `lib/normandy/context/window_manager.ex`:

(a) Replace the single alias line `alias Normandy.Components.AgentMemory` with:

```elixir
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.BaseIOSchema
  alias Normandy.Components.TranscriptIntegrity
```

(b) Replace `truncate_oldest_first/2` with:

```elixir
  defp truncate_oldest_first(agent, manager) do
    target_tokens = manager.max_tokens - manager.reserved_tokens
    current_tokens = estimate_conversation_tokens(agent.memory)

    if current_tokens <= target_tokens do
      {:ok, agent}
    else
      # Operate on entries (turn_id/role/struct content intact), not on the
      # serialized history/1 view: the cut must snap to turn boundaries and
      # the rebuild must not downgrade struct content.
      entries = AgentMemory.history_entries(agent.memory)
      {keep_entries, _removed_count} = split_to_fit(entries, target_tokens)

      new_memory = rebuild_memory(keep_entries, agent.memory)
      {:ok, %{agent | memory: new_memory}}
    end
  end
```

(c) Replace `split_to_fit/2` with (and add `estimate_entry_tokens/1` below it):

```elixir
  # Newest entries that fit `target_tokens`, snapped backward to a turn
  # boundary via TranscriptIntegrity.snap_cut/2 so a cut can never orphan a
  # tool_result from its tool_use. Snapping rounds UP: the kept suffix may
  # exceed target_tokens by up to one turn — an orphaned transcript is never
  # the right trade.
  defp split_to_fit(entries, target_tokens) do
    {desired_count, _tokens} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({0, 0}, fn entry, {count, tokens} ->
        entry_tokens = estimate_entry_tokens(entry)

        if tokens + entry_tokens <= target_tokens do
          {:cont, {count + 1, tokens + entry_tokens}}
        else
          {:halt, {count, tokens}}
        end
      end)

    keep = TranscriptIntegrity.snap_cut(entries, desired_count)
    {keep, length(entries) - length(keep)}
  end

  # Estimate on the same serialized view estimate_conversation_tokens/1 uses
  # (history/1 feeds it BaseIOSchema.to_json output), so the within-limit
  # trigger and the split agree on token counts.
  defp estimate_entry_tokens(%Entry{content: content}) do
    estimate_message_content_tokens(BaseIOSchema.to_json(content)) + 10
  end
```

(d) Replace `rebuild_memory/2` with:

```elixir
  # Rebuild from surviving entries rather than serialized history maps: turn
  # ids, roles, and struct content survive truncation intact (the old
  # map-based rebuild permanently downgraded struct content and collapsed
  # every survivor into the current turn). The oldest survivor is re-rooted;
  # max_messages is restored WITHOUT re-running cap enforcement here — the
  # (turn-aware) cap re-applies on the next add_message/3.
  defp rebuild_memory([], original_memory) do
    %{
      AgentMemory.new_memory(Map.get(original_memory, :max_messages))
      | current_turn_id: Map.get(original_memory, :current_turn_id)
    }
  end

  defp rebuild_memory([oldest | rest], original_memory) do
    rebuilt = AgentMemory.from_entries([%{oldest | parent_id: nil} | rest])

    %{
      rebuilt
      | max_messages: Map.get(original_memory, :max_messages),
        current_turn_id: Map.get(original_memory, :current_turn_id)
    }
  end
```

- [ ] **Step 5: Run the touched files, then the whole suite**

Run: `mix format && mix test test/context/window_manager_test.exs test/behaviours/compactor_test.exs`
Expected: PASS (new test: exactly 10 entries survive — two whole turns).
Run: `mix test`
Expected: previous totals + 1, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/context/window_manager.ex test/context/window_manager_test.exs test/behaviours/compactor_test.exs
git commit -m "feat(context): turn-aware window truncation, rebuild memory from entries"
```

---

### Task 5: Stage 2b — Summarizer snaps its split and rebuilds from entries

**Files:**
- Modify: `lib/normandy/context/summarizer.ex` (`compress_conversation/3`, `do_compress_conversation/7`, `rebuild_memory_with_summary/4`; two new aliases)
- Modify: `test/context/summarizer_test.exs` (update three existing builders; add three aliases and one new test)
- Modify: `test/context/window_manager_test.exs` (update the `"summarizes old messages when client is available"` builder)

**Interfaces:**
- Produces: no public signature changes. `compress_conversation/3` splits on entries with `snap_cut(entries, keep_recent)` — "keep the newest `keep_recent` entries rounded up to whole turns"; when snapping absorbs everything into the recent window, it returns `{:ok, agent}` unchanged (nothing to summarize). `rebuild_memory_with_summary/4` builds the summary as a root `Entry` with its OWN fresh `turn_id` and relinks the oldest kept entry to it.
- Consumes: `AgentMemory.history_entries/1` (Task 3), `TranscriptIntegrity.snap_cut/2` (Task 1), `AgentMemory.from_entries/1`, `UUID.uuid4/0`.
- Unchanged: `summarize_messages/4` (it already only touches `msg.role`/`msg.content`, which both `%{role:, content:}` maps and `Entry` structs satisfy; `extract_content/1`'s `is_map` clause Poison-encodes struct content — Poison's `Any` encoder handles arbitrary structs), `format_messages_for_summary/1`, `estimate_savings/2`, `call_llm_for_summary/5`.

- [ ] **Step 1: Update the existing single-turn test builders (suite must stay green)**

Same rationale as Task 4 Step 1 — one turn per message, passes against BOTH old and new code.

(a) `test/context/summarizer_test.exs`, `"compresses conversation by summarizing old messages"` — replace the builder with:

```elixir
      memory =
        Enum.reduce(1..20, AgentMemory.new_memory(), fn i, mem ->
          mem
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", "Message #{i}")
        end)
```

(b) `"uses custom summary role when provided"` — same shape, `1..15`.

(c) `"preserves most recent messages"` — same shape, `1..10`.

Leave `"keeps all messages if below keep_recent threshold"` alone (2 messages, `keep_recent: 10` — the `total <= keep_recent` clause is unchanged and turn-blind).

(d) `test/context/window_manager_test.exs`, `"summarizes old messages when client is available"` — replace the builder with:

```elixir
      memory =
        Enum.reduce(1..15, AgentMemory.new_memory(), fn i, mem ->
          mem
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", "Message number #{i} with content here")
        end)
```

Run: `mix format && mix test test/context/summarizer_test.exs test/context/window_manager_test.exs`
Expected: PASS.

- [ ] **Step 2: Add the failing turn-aware test**

In `test/context/summarizer_test.exs`, add to the alias block:

```elixir
  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
```

Then append a new describe block:

```elixir
  describe "turn-aware compression" do
    test "keep_recent snaps up to a whole turn and preserves tool pairing", %{client: client} do
      # Three turns of four entries: user -> assistant tool_use -> tool result
      # -> assistant final. All four share one turn_id, exactly as BaseAgent
      # builds them during a tool loop.
      memory =
        Enum.reduce(1..3, AgentMemory.new_memory(), fn t, mem ->
          call_id = "call_#{t}"

          mem
          |> AgentMemory.initialize_turn()
          |> AgentMemory.add_message("user", "question #{t}")
          |> AgentMemory.add_message("assistant", %ToolCallResponse{
            tool_calls: [%ToolCall{id: call_id, name: "lookup", input: %{"q" => "#{t}"}}]
          })
          |> AgentMemory.add_message("tool", %ToolResult{
            tool_call_id: call_id,
            output: %{"answer" => "#{t}"}
          })
          |> AgentMemory.add_message("assistant", %ToolCallResponse{
            content: "answer #{t}",
            tool_calls: []
          })
        end)

      agent = %{memory: memory, config: %{client: client, model: "test-model"}}

      # keep_recent: 2 lands mid-turn; the split must snap up to the newest
      # whole turn (4 entries) and summarize the other two turns.
      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 2)

      entries = AgentMemory.history_entries(compressed.memory)

      assert Enum.map(entries, & &1.role) == ["system", "user", "assistant", "tool", "assistant"]

      [_summary, _user, tool_use, tool_result, _final] = entries
      assert %ToolCallResponse{tool_calls: [%ToolCall{id: call_id}]} = tool_use.content
      assert %ToolResult{tool_call_id: ^call_id} = tool_result.content
    end
  end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix format && mix test test/context/summarizer_test.exs`
Expected: FAIL — the new test only. Old code splits the serialized history at `total - 2`, keeping `["system", "tool", "assistant"]` (an orphaned tool result, downgraded content). Everything else passes.

- [ ] **Step 4: Implement**

In `lib/normandy/context/summarizer.ex`:

(a) Replace the alias block at the top with:

```elixir
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.Message
  alias Normandy.Components.TranscriptIntegrity
```

(b) Replace `compress_conversation/3`'s body (keep the `@doc` and `@spec`) with:

```elixir
  def compress_conversation(client, agent, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, 10)
    summary_role = Keyword.get(opts, :summary_role, "system")

    entries = AgentMemory.history_entries(agent.memory)
    total_messages = length(entries)

    do_compress_conversation(
      client,
      agent,
      entries,
      total_messages,
      keep_recent,
      summary_role,
      opts
    )
  end
```

(c) In the first `do_compress_conversation/7` clause (the `total_messages <= keep_recent` guard), rename the `_history` parameter to `_entries` (behavior unchanged). Replace the second clause with:

```elixir
  defp do_compress_conversation(
         client,
         agent,
         entries,
         total_messages,
         keep_recent,
         summary_role,
         opts
       ) do
    # Snap the split to a turn boundary: recent = the newest `keep_recent`
    # entries rounded up to whole turns, so a tool_result is never severed
    # from its tool_use.
    recent_entries = TranscriptIntegrity.snap_cut(entries, keep_recent)
    old_entries = Enum.take(entries, total_messages - length(recent_entries))

    case old_entries do
      [] ->
        # Snapping absorbed everything into the recent window — nothing to summarize.
        {:ok, agent}

      _ ->
        case summarize_messages(client, agent, old_entries, opts) do
          {:ok, summary} ->
            new_memory =
              rebuild_memory_with_summary(agent.memory, summary, summary_role, recent_entries)

            {:ok, %{agent | memory: new_memory}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
```

(d) Replace `rebuild_memory_with_summary/4` with:

```elixir
  # Rebuild from surviving entries rather than serialized history maps: turn
  # ids, roles, and struct content survive compression intact. The summary
  # entry gets its OWN turn_id (it summarizes many turns and belongs to none),
  # so deleting the active turn later cannot take the summary with it.
  # max_messages is restored WITHOUT re-running cap enforcement here — the
  # (turn-aware) cap re-applies on the next add_message/3.
  defp rebuild_memory_with_summary(original_memory, summary, summary_role, recent_entries) do
    summary_content = %Normandy.Agents.BaseAgentOutputSchema{
      chat_message: "Previous conversation summary: " <> summary
    }

    summary_entry = %Entry{
      id: UUID.uuid4(),
      parent_id: nil,
      turn_id: UUID.uuid4(),
      role: summary_role,
      content: summary_content
    }

    recent =
      case recent_entries do
        [] -> []
        [oldest | rest] -> [%{oldest | parent_id: summary_entry.id} | rest]
      end

    rebuilt = AgentMemory.from_entries([summary_entry | recent])

    %{
      rebuilt
      | max_messages: Map.get(original_memory, :max_messages),
        current_turn_id: Map.get(original_memory, :current_turn_id)
    }
  end
```

(e) In `summarize_messages/4`'s `@doc`, append one line to the description (before `## Options`):

```
  Accepts plain `%{role:, content:}` maps or `AgentMemory.Entry` structs.
```

- [ ] **Step 5: Run the touched files, then the whole suite**

Run: `mix format && mix test test/context/summarizer_test.exs test/context/window_manager_test.exs test/behaviours/compactor_test.exs`
Expected: PASS — including compactor's `":summarize strategy returns error meta..."` (its 10 per-message turns split 5/5, so the error branch still fires).
Run: `mix test`
Expected: previous totals + 1, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/context/summarizer.ex test/context/summarizer_test.exs test/context/window_manager_test.exs
git commit -m "feat(context): turn-aware summarizer split, rebuild summary memory from entries"
```

---

### Task 6: Shared regression net — tool-loop generator through all three truncation paths

**Files:**
- Create: `test/context/turn_aware_truncation_test.exs`

**Interfaces:**
- Produces: nothing (test-only). This is the spec-mandated shared test: a generator producing multi-iteration tool-loop conversations (user → assistant `ToolCallResponse` with `tool_use` → `"tool"`-role `ToolResult` → … → assistant final), run through ALL THREE truncation paths, asserting the three invariants.
- Consumes: everything from Tasks 1-5; `Normandy.Test.MockSummarizerClient` (existing, `test/support/mock_summarizer_client.ex`).

- [ ] **Step 1: Write the test file**

Create `test/context/turn_aware_truncation_test.exs`:

```elixir
defmodule Normandy.Context.TurnAwareTruncationTest do
  @moduledoc """
  Shared regression net for Fix 4 (turn-aware truncation).

  One generator builds realistic multi-iteration tool-loop conversations; the
  same three invariants are asserted after each of the three truncation paths:

  1. no surviving history starts with role "tool"
  2. every surviving tool_result's tool_use is in the surviving history
  3. every surviving tool_use has all its results
  """

  use ExUnit.Case, async: true

  alias Normandy.Agents.ToolCallResponse
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Context.Summarizer
  alias Normandy.Context.WindowManager
  alias Normandy.Test.MockSummarizerClient

  # Entries per generated turn: user + iterations x (assistant tool_use +
  # tool result) + assistant final. With 3 iterations: 1 + 6 + 1 = 8.
  @iterations 3
  @turn_size 2 + 2 * @iterations

  # ── Generator ───────────────────────────────────────────────────────────────

  # Builds `turns` user turns; each turn is a tool loop:
  #   user -> (assistant ToolCallResponse[tool_use] -> tool ToolResult) x @iterations
  #        -> assistant final.
  # Every entry of a turn shares one turn_id (initialize_turn once per turn),
  # mirroring exactly how BaseAgent.prepare_input/2 + the Turn effects build
  # memory during a real tool loop.
  defp tool_loop_memory(turns, max_messages \\ nil) do
    Enum.reduce(1..turns, AgentMemory.new_memory(max_messages), fn t, mem ->
      mem = AgentMemory.initialize_turn(mem)
      mem = AgentMemory.add_message(mem, "user", "question #{t}: please look things up")

      mem =
        Enum.reduce(1..@iterations, mem, fn i, m ->
          call_id = "call_#{t}_#{i}"

          m
          |> AgentMemory.add_message("assistant", %ToolCallResponse{
            tool_calls: [
              %ToolCall{id: call_id, name: "search", input: %{"query" => "q #{t}-#{i}"}}
            ]
          })
          |> AgentMemory.add_message("tool", %ToolResult{
            tool_call_id: call_id,
            output: %{"result" => "answer #{t}-#{i}"},
            is_error: false
          })
        end)

      AgentMemory.add_message(mem, "assistant", %ToolCallResponse{
        content: "final answer for question #{t}",
        tool_calls: []
      })
    end)
  end

  # ── Shared invariant assertions ─────────────────────────────────────────────

  defp assert_no_orphans(memory) do
    entries = AgentMemory.history_entries(memory)

    # (1) The surviving history never starts with a tool result.
    case entries do
      [] -> :ok
      [first | _] -> refute first.role == "tool", "history starts with role \"tool\""
    end

    tool_use_ids =
      for %Entry{role: "assistant", content: %ToolCallResponse{tool_calls: calls}} <- entries,
          %ToolCall{id: id} <- calls,
          into: MapSet.new(),
          do: id

    tool_result_ids =
      for %Entry{role: "tool", content: %ToolResult{tool_call_id: id}} <- entries,
          into: MapSet.new(),
          do: id

    # (2) Every surviving tool_result's tool_use is in the surviving history.
    orphaned_results = MapSet.difference(tool_result_ids, tool_use_ids)

    assert MapSet.size(orphaned_results) == 0,
           "tool_results without their tool_use: #{inspect(MapSet.to_list(orphaned_results))}"

    # (3) Every surviving tool_use has all its results.
    unanswered_calls = MapSet.difference(tool_use_ids, tool_result_ids)

    assert MapSet.size(unanswered_calls) == 0,
           "tool_use without its tool_result: #{inspect(MapSet.to_list(unanswered_calls))}"

    entries
  end

  # ── Path 1: enforce_max_messages (runs on every add_message, mid-loop) ─────

  test "max_messages cap never orphans tool pairings, across a sweep of caps" do
    # Enforcement fires DURING construction — including mid-tool-loop, the
    # exact defect scenario. 5 turns x 8 entries = 40 entries uncapped.
    for max <- 1..12 do
      memory = tool_loop_memory(5, max)
      count = AgentMemory.count_messages(memory)

      assert_no_orphans(memory)
      assert count >= max, "cap #{max}: kept #{count} (< cap)"
      assert rem(count, @turn_size) == 0, "cap #{max}: kept #{count} (partial turn)"
      assert count < 40, "cap #{max}: nothing was ever truncated"
    end
  end

  # ── Path 2: WindowManager.ensure_within_limit (split_to_fit) ───────────────

  test "token-budget truncation never orphans tool pairings, across budgets" do
    agent = %{memory: tool_loop_memory(6), config: %{}}

    for max_tokens <- [100, 250, 500, 800, 1200] do
      manager = WindowManager.new(max_tokens: max_tokens, reserved_tokens: 30)

      {:ok, truncated} = WindowManager.ensure_within_limit(agent, manager)

      entries = assert_no_orphans(truncated.memory)

      assert entries != [], "budget #{max_tokens}: everything was dropped"
      assert length(entries) < 48, "budget #{max_tokens}: nothing was truncated"

      assert rem(length(entries), @turn_size) == 0,
             "budget #{max_tokens}: partial turn survived (#{length(entries)} entries)"
    end
  end

  # ── Path 3: Summarizer.compress_conversation ───────────────────────────────

  test "summarization never orphans tool pairings, across keep_recent values" do
    client = %MockSummarizerClient{summary_response: "compressed history"}
    agent = %{memory: tool_loop_memory(5), config: %{client: client, model: "test-model"}}

    for keep <- [1, 3, 8, 9, 17] do
      {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: keep)

      entries = assert_no_orphans(compressed.memory)

      # Summary entry + whole turns only.
      assert hd(entries).role == "system"

      assert rem(length(entries) - 1, @turn_size) == 0,
             "keep_recent #{keep}: partial turn survived (#{length(entries)} entries)"
    end
  end

  test "summarization keeps exactly the newest whole turn when keep_recent lands mid-turn" do
    client = %MockSummarizerClient{summary_response: "compressed history"}
    agent = %{memory: tool_loop_memory(5), config: %{client: client, model: "test-model"}}

    {:ok, compressed} = Summarizer.compress_conversation(client, agent, keep_recent: 3)

    entries = assert_no_orphans(compressed.memory)

    # keep_recent: 3 snaps up to the newest whole turn (8 entries) + summary.
    assert length(entries) == 1 + @turn_size

    assert Enum.map(entries, & &1.role) == [
             "system",
             "user",
             "assistant",
             "tool",
             "assistant",
             "tool",
             "assistant",
             "tool",
             "assistant"
           ]
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix format && mix test test/context/turn_aware_truncation_test.exs`
Expected: PASS (4 tests, 0 failures) — this is the regression net over already-implemented behavior. **If ANY assertion fails here, STOP (RULE 0): one of the three paths is broken. Do not patch the test; report which path and which invariant failed.**

- [ ] **Step 3: Run the whole suite**

Run: `mix test`
Expected: previous totals + 4, 0 failures. (Cumulative new tests this plan: 5 + 3 + 1 + 1 + 1 + 4 = 15.)

- [ ] **Step 4: Commit**

```bash
git add test/context/turn_aware_truncation_test.exs
git commit -m "test(context): tool-loop integrity net across all three truncation paths"
```

---

### Task 7: Final verification and handoff

**Files:** none modified.

- [ ] **Step 1: Full verification gate**

Run, in order:

```bash
mix format --check-formatted
mix test
mix dialyzer
```

Expected: no formatting diffs; full suite = Task 0 baseline + 15 new tests, 0 failures; Dialyzer clean (the CI gate was re-enabled in `cf8fd08` — a new warning here fails CI, fix it before finishing).

- [ ] **Step 2: Confirm the commit trail**

Run: `git log --oneline -6`
Expected: the five commits from Tasks 1-6 (Task 0 makes none), each adding only its listed files, no AI attribution.

- [ ] **Step 3: Handoff report to Q**

State explicitly:
1. All three truncation paths now cut on turn boundaries via `TranscriptIntegrity.snap_cut/2`; the shared tool-loop net covers all three.
2. The five documented behavior changes (see plan header) — especially that `max_messages` is now "at least N, whole turns" and that a single oversized turn is kept whole.
3. Which pre-existing tests were updated to per-message-turn builders (Tasks 2/4/5 lists) and why.
4. No version bump made by hand — the cocogitto autopublish pipeline derives it from the `feat(...)` commits.
