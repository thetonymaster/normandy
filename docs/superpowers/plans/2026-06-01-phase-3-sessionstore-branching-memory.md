# Phase 3 — SessionStore + Branching AgentMemory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `AgentMemory` from a linear reverse-prepend list into a struct of parent-linked entries (branching via `fork/2`), and add `Normandy.Behaviours.SessionStore` (in-memory + ETS impls) as the persistence seam — preserving linear-conversation observable behavior as the correctness oracle.

**Architecture:** A linear conversation is a degenerate single-parent chain; `history/1` walks `head → root` and reverses, producing output byte-identical to today. The change is staged **PREP → SWAP**: PREP adds `messages/1`/`latest_message/1` to the *current* list-based module and migrates every consumer + white-box test off the raw `.history` field (no struct change, suite green); SWAP changes the representation behind the now-stable public API (suite green = parity proof). `SessionStore` is defined + defaulted + contract-tested against `InMemory` and `ETS`; its turn-state half round-trips an opaque term with no real consumer until Phase 4.

**Tech Stack:** Elixir, ExUnit, `:ets`, `Agent`, Poison (JSON adapter via `Application.get_env(:normandy, :adapter)`), `elixir_uuid` (`UUID.uuid4/0`).

**Spec:** `docs/superpowers/specs/2026-06-01-phase-3-sessionstore-branching-memory-design.md`

**Gates (run at every Commit step):** `mix format` → `mix compile --warnings-as-errors --force` (clean) → `mix test` (full suite green; baseline 71 doctests, 25 properties, 1162 tests, 0 failures, 13 skipped). No AI attribution in commits. Add files individually — never `git add .`.

**Note on test edits:** all test-site migrations use the fully-qualified `Normandy.Components.AgentMemory.<fn>(...)` so no `alias` management is needed in any test file.

---

### Task 1: `AgentMemory.Entry` struct

**Files:**
- Create: `lib/normandy/components/agent_memory/entry.ex`
- Test: `test/components/agent_memory/entry_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/components/agent_memory/entry_test.exs`:

```elixir
defmodule NormandyTest.Components.AgentMemory.EntryTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory.Entry

  test "an Entry carries id, parent_id, turn_id, role, content" do
    entry = %Entry{id: "e1", parent_id: nil, turn_id: "t1", role: "user", content: %{hello: "world"}}

    assert entry.id == "e1"
    assert entry.parent_id == nil
    assert entry.turn_id == "t1"
    assert entry.role == "user"
    assert entry.content == %{hello: "world"}
  end

  test "parent_id defaults to nil (a root entry)" do
    assert %Entry{}.parent_id == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/components/agent_memory/entry_test.exs`
Expected: FAIL — `Normandy.Components.AgentMemory.Entry.__struct__/0 is undefined`.

- [ ] **Step 3: Create the Entry struct**

Create `lib/normandy/components/agent_memory/entry.ex`:

```elixir
defmodule Normandy.Components.AgentMemory.Entry do
  @moduledoc """
  One message in the conversation graph.

  Each entry is parent-linked: `parent_id` points to the prior entry on its
  branch (`nil` for a root). A linear conversation is a degenerate single-parent
  chain; branches are siblings sharing a `parent_id`.
  """

  defstruct [:id, :parent_id, :turn_id, :role, :content]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          turn_id: String.t(),
          role: String.t(),
          content: struct() | map() | list()
        }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/components/agent_memory/entry_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/normandy/components/agent_memory/entry.ex test/components/agent_memory/entry_test.exs
git commit -m "feat(memory): add AgentMemory.Entry parent-linked struct"
```

---

### Task 2: PREP — add accessors, migrate consumers + white-box tests (no struct change)

Add `messages/1` + `latest_message/1` to the **current** list-based `AgentMemory`, then move the two `base_agent` pattern-matches and all ~21 white-box test sites off the raw `.history` field. No representation change yet — the suite must stay green on the existing implementation. Commit only at Step 9 when the full suite is green.

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (add two functions)
- Modify: `lib/normandy/agents/base_agent.ex:1316-1338`
- Modify: `test/dsl/agent_test.exs`
- Modify: `test/integration/agent_context_management_test.exs`
- Modify: `test/normandy_integration/dsl_comprehensive_test.exs`
- Modify: `test/integration/agent_resilience_integration_test.exs`
- Modify: `test/integration/llm_caching_integration_test.exs`
- Modify: `test/integration/agent_tool_execution_flow_test.exs`
- Modify: `test/agents/base_agent_tool_loop_test.exs`
- Modify: `test/agents/base_agent_streaming_guardrails_test.exs`

- [ ] **Step 1: Add `messages/1` + `latest_message/1` to the current module**

In `lib/normandy/components/agent_memory.ex`, add these two functions immediately after `history/1` (the module already aliases `Normandy.Components.Message`):

```elixir
  @doc "The conversation as `%Message{}` structs, chronological (oldest -> newest)."
  @spec messages(t()) :: [Message.t()]
  def messages(memory) do
    memory |> Map.get(:history, []) |> Enum.reverse()
  end

  @doc "The newest message, or nil when empty."
  @spec latest_message(t()) :: Message.t() | nil
  def latest_message(memory) do
    case Map.get(memory, :history, []) do
      [latest | _] -> latest
      [] -> nil
    end
  end
```

- [ ] **Step 2: Migrate `base_agent.ex` (`pending_tool_call_count/1`, `completed_iterations/1`)**

In `lib/normandy/agents/base_agent.ex`, replace the block at lines 1316-1338:

```elixir
  defp pending_tool_call_count(%BaseAgentConfig{memory: %{history: [latest | _]}})
       when latest.role == "assistant" do
    latest.content
    |> Map.get(:tool_calls, [])
    |> length()
  end

  defp pending_tool_call_count(_), do: 0

  defp completed_iterations({%BaseAgentConfig{memory: %{history: history}}, _response}) do
    assistant_turn_id =
      history
      |> Enum.find_value(fn
        %Message{role: "assistant", turn_id: turn_id} -> turn_id
        _ -> nil
      end)

    history
    |> Enum.count(fn
      %Message{role: "assistant", turn_id: ^assistant_turn_id} -> true
      _ -> false
    end)
  end
```

with:

```elixir
  defp pending_tool_call_count(%BaseAgentConfig{memory: memory}) do
    case AgentMemory.latest_message(memory) do
      %Message{role: "assistant", content: content} ->
        content |> Map.get(:tool_calls, []) |> length()

      _ ->
        0
    end
  end

  defp completed_iterations({%BaseAgentConfig{memory: memory}, _response}) do
    messages = AgentMemory.messages(memory)

    assistant_turn_id =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: "assistant", turn_id: turn_id} -> turn_id
        _ -> nil
      end)

    Enum.count(messages, fn
      %Message{role: "assistant", turn_id: ^assistant_turn_id} -> true
      _ -> false
    end)
  end
```

(`AgentMemory` and `Message` are already aliased at the top of this file.)

- [ ] **Step 3: Checkpoint — run the base_agent + memory tests**

Run: `mix test test/agents/ test/components/agent_memory_test.exs`
Expected: PASS — the accessors behave identically to the old field access, so iteration counting is unchanged.

- [ ] **Step 4: Migrate `test/dsl/agent_test.exs` (8 sites)**

Apply these replacements (use replace-all where noted):

- Replace **all** occurrences of
  `Enum.find(updated_agent.memory.history, fn msg -> msg.role == "user" end)`
  with
  `Enum.find(Normandy.Components.AgentMemory.messages(updated_agent.memory), fn msg -> msg.role == "user" end)`
  (3 occurrences).
- Replace **all** `assert length(agent.memory.history) > 0` with
  `assert Normandy.Components.AgentMemory.count_messages(agent.memory) > 0` (2 occurrences).
- Replace **all** `assert length(agent.memory.history) == 0` with
  `assert Normandy.Components.AgentMemory.count_messages(agent.memory) == 0` (2 occurrences).
- Replace `assert length(agent.memory.history) > 2` with
  `assert Normandy.Components.AgentMemory.count_messages(agent.memory) > 2` (1 occurrence).

- [ ] **Step 5: Migrate `test/integration/agent_context_management_test.exs` (6 sites)**

- `      history = agent.memory.history` → `      history = Normandy.Components.AgentMemory.messages(agent.memory)`
- `assert length(final_agent.memory.history) >= 6` → `assert Normandy.Components.AgentMemory.count_messages(final_agent.memory) >= 6`
- `assert length(agent.memory.history) >= 6` → `assert Normandy.Components.AgentMemory.count_messages(agent.memory) >= 6`
- `assert length(final_agent.memory.history) >= 20` → `assert Normandy.Components.AgentMemory.count_messages(final_agent.memory) >= 20`
- `assert is_list(agent.memory.history)` → `assert is_list(Normandy.Components.AgentMemory.messages(agent.memory))`
- `assert Enum.all?(agent.memory.history, fn msg ->` → `assert Enum.all?(Normandy.Components.AgentMemory.messages(agent.memory), fn msg ->`

- [ ] **Step 6: Migrate the four single-site / double-site integration files**

`test/normandy_integration/dsl_comprehensive_test.exs`:
- `assert length(updated_agent.memory.history) > 0` → `assert Normandy.Components.AgentMemory.count_messages(updated_agent.memory) > 0`
- `assert length(updated_agent2.memory.history) > length(updated_agent.memory.history)` → `assert Normandy.Components.AgentMemory.count_messages(updated_agent2.memory) > Normandy.Components.AgentMemory.count_messages(updated_agent.memory)`
- `assert length(reset_agent.memory.history) == 0` → `assert Normandy.Components.AgentMemory.count_messages(reset_agent.memory) == 0`

`test/integration/agent_resilience_integration_test.exs`:
- `assert agent2.memory.history != []` → `assert Normandy.Components.AgentMemory.count_messages(agent2.memory) != 0`
- `assert length(agent2.memory.history) >= 4` → `assert Normandy.Components.AgentMemory.count_messages(agent2.memory) >= 4`

`test/integration/llm_caching_integration_test.exs`:
- `assert length(agent1.memory.history) >= 6` → `assert Normandy.Components.AgentMemory.count_messages(agent1.memory) >= 6`

`test/integration/agent_tool_execution_flow_test.exs`:
- `      history = memory.history` → `      history = Normandy.Components.AgentMemory.messages(memory)`

- [ ] **Step 7: Migrate the two order-sensitive filter sites**

`test/agents/base_agent_tool_loop_test.exs` — replace:

```elixir
      # `memory.history` is stored LIFO ([newest | rest]) for O(1) prepends.
      # Reverse to get chronological order before filtering.
      tool_msgs =
        agent.memory.history
        |> Enum.reverse()
        |> Enum.filter(&(&1.role == "tool"))
```

with:

```elixir
      # AgentMemory.messages/1 returns the conversation chronological.
      tool_msgs =
        Normandy.Components.AgentMemory.messages(agent.memory)
        |> Enum.filter(&(&1.role == "tool"))
```

`test/agents/base_agent_streaming_guardrails_test.exs` — replace:

```elixir
      assistant_entries =
        updated_agent.memory.history
        |> Enum.filter(&(&1.role == "assistant"))
```

with:

```elixir
      assistant_entries =
        Normandy.Components.AgentMemory.messages(updated_agent.memory)
        |> Enum.filter(&(&1.role == "assistant"))
```

- [ ] **Step 8: Run the full suite (green on the current impl)**

Run: `mix format && mix compile --warnings-as-errors --force && mix test`
Expected: PASS — full suite at baseline. No `.memory.history` field reads remain outside `agent_memory.ex` and its unit test. Verify with:
`grep -rn "memory\.history" lib/ test/ --include="*.ex" --include="*.exs" | grep -v "components/agent_memory"`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/agents/base_agent.ex \
        test/dsl/agent_test.exs test/integration/agent_context_management_test.exs \
        test/normandy_integration/dsl_comprehensive_test.exs \
        test/integration/agent_resilience_integration_test.exs \
        test/integration/llm_caching_integration_test.exs \
        test/integration/agent_tool_execution_flow_test.exs \
        test/agents/base_agent_tool_loop_test.exs \
        test/agents/base_agent_streaming_guardrails_test.exs
git commit -m "refactor(memory): migrate consumers + tests onto messages/1 + count_messages/1"
```

---

### Task 3: SWAP — rewrite `AgentMemory` as the entry graph

Change the representation behind the now-stable public API. Only `agent_memory.ex`, its unit test, and the two `rebuild_memory*` bare-map constructions change; everything migrated in Task 2 keeps passing because `messages/1`/`latest_message/1`/`count_messages/1` produce identical results on the new impl. The full-suite green at Step 6 is the **parity proof**.

**Files:**
- Modify (full rewrite): `lib/normandy/components/agent_memory.ex`
- Modify (full rewrite): `test/components/agent_memory_test.exs`
- Modify: `lib/normandy/context/window_manager.ex:354-371`
- Modify: `lib/normandy/context/summarizer.ex:211-221`

- [ ] **Step 1: Rewrite the AgentMemory unit test file**

Replace the entire contents of `test/components/agent_memory_test.exs` with:

```elixir
defmodule NormandyTest.Components.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias NormandyTest.IOTest
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.Message
  doctest Normandy.Components.AgentMemory

  test "new_memory builds an empty entry graph" do
    memory = AgentMemory.new_memory(10)

    assert memory.max_messages == 10
    assert memory.entries == %{}
    assert memory.head == nil
    assert memory.current_turn_id == nil
  end

  test "custom memory max_messages" do
    assert AgentMemory.new_memory(20).max_messages == 20
  end

  test "initialize_turn mints a fresh current_turn_id each call" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    turn_id = AgentMemory.get_current_turn_id(memory)
    assert turn_id != nil

    turn_id_after =
      memory |> AgentMemory.initialize_turn() |> AgentMemory.get_current_turn_id()

    assert turn_id != turn_id_after
  end

  test "add_message links each entry to the prior head" do
    memory = AgentMemory.new_memory()
    content_a = %{hello: "goodbye"}
    memory = AgentMemory.add_message(memory, "main", content_a)
    turn_id = AgentMemory.get_current_turn_id(memory)

    assert turn_id != nil
    assert AgentMemory.count_messages(memory) == 1
    assert [%Message{role: "main", content: ^content_a, turn_id: ^turn_id}] =
             AgentMemory.messages(memory)

    content_b = %{goodbye: "hello"}
    memory = AgentMemory.add_message(memory, "secondary", content_b)

    assert [
             %Message{role: "main", content: ^content_a},
             %Message{role: "secondary", content: ^content_b}
           ] = AgentMemory.messages(memory)

    assert AgentMemory.latest_message(memory).role == "secondary"
  end

  test "max_messages overflow keeps only the newest entries" do
    memory = AgentMemory.new_memory(1)
    memory = AgentMemory.add_message(memory, "main", %{hello: "goodbye"})
    memory = AgentMemory.add_message(memory, "secondary", %{goodbye: "hello"})

    assert AgentMemory.count_messages(memory) == 1
    assert [%Message{role: "secondary"}] = AgentMemory.messages(memory)
  end

  test "history reconstructs the chronological role/content view" do
    content_a = %IOTest{}
    content_b = %IOTest{test_field: "hello there"}

    history =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", content_a)
      |> AgentMemory.add_message("system", content_b)
      |> AgentMemory.history()

    assert history == [
             %{role: "user", content: "{\"test_field\":\"test_value\"}"},
             %{role: "system", content: "{\"test_field\":\"hello there\"}"}
           ]
  end

  test "list-shaped content survives history/1 verbatim" do
    blocks = [
      %{"type" => "text", "text" => "describe this"},
      %{"type" => "image", "source" => %{"type" => "url", "url" => "https://example.com/a.png"}}
    ]

    history =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", blocks)
      |> AgentMemory.history()

    assert history == [%{role: "user", content: blocks}]
  end

  test "get_current_turn_id" do
    memory = AgentMemory.new_memory()
    assert AgentMemory.get_current_turn_id(memory) == nil

    memory = AgentMemory.initialize_turn(memory)
    assert AgentMemory.get_current_turn_id(memory) != nil
  end

  test "count_messages" do
    memory = AgentMemory.new_memory()
    assert AgentMemory.count_messages(memory) == 0

    memory = AgentMemory.add_message(memory, "user", %IOTest{})
    assert AgentMemory.count_messages(memory) == 1
  end

  test "latest_message is nil for empty memory" do
    assert AgentMemory.latest_message(AgentMemory.new_memory()) == nil
  end

  test "dump and load round-trips through the JSON adapter" do
    content_a = %IOTest{}
    content_b = %IOTest{test_field: "hello there"}

    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", content_a)
      |> AgentMemory.add_message("system", content_b)

    loaded = memory |> AgentMemory.dump() |> AgentMemory.load()

    assert AgentMemory.count_messages(loaded) == 2
    assert AgentMemory.get_current_turn_id(memory) == AgentMemory.get_current_turn_id(loaded)
    assert memory.max_messages == loaded.max_messages

    assert AgentMemory.history(loaded) == [
             %{role: "user", content: "{\"test_field\":\"test_value\"}"},
             %{role: "system", content: "{\"test_field\":\"hello there\"}"}
           ]
  end

  test "dump tolerates raw (non-struct) content" do
    memory = AgentMemory.new_memory() |> AgentMemory.add_message("user", %{a: 1})
    loaded = memory |> AgentMemory.dump() |> AgentMemory.load()
    assert AgentMemory.count_messages(loaded) == 1
  end

  test "memory with no limits keeps everything" do
    memory =
      Enum.reduce(1..100, AgentMemory.new_memory(), fn x, mem ->
        AgentMemory.add_message(mem, "user", %IOTest{test_field: "hello #{x}"})
      end)

    assert AgentMemory.count_messages(memory) == 100
  end

  test "memory with limit zero stores nothing" do
    memory = AgentMemory.new_memory(0) |> AgentMemory.add_message("user", %IOTest{})
    assert AgentMemory.count_messages(memory) == 0
  end

  test "turn consistency across initialize_turn" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    turn_id = AgentMemory.get_current_turn_id(memory)
    assert turn_id != nil

    memory =
      memory
      |> AgentMemory.add_message("user", %IOTest{test_field: "hello 1"})
      |> AgentMemory.add_message("user", %IOTest{test_field: "hello 2"})

    assert Enum.all?(AgentMemory.messages(memory), &(&1.turn_id == turn_id))

    memory = AgentMemory.initialize_turn(memory)
    new_turn_id = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "user", %IOTest{test_field: "hello 3"})

    assert new_turn_id != turn_id
    assert AgentMemory.latest_message(memory).turn_id == new_turn_id
  end

  test "delete_turn splices entries and raises on a missing turn" do
    memory = AgentMemory.new_memory() |> AgentMemory.initialize_turn()
    initial_turn_id = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "user", %IOTest{test_field: "hello"})

    memory = AgentMemory.initialize_turn(memory)
    other_turn_id = AgentMemory.get_current_turn_id(memory)
    memory = AgentMemory.add_message(memory, "user", %IOTest{test_field: "goodbye"})

    assert AgentMemory.count_messages(memory) == 2

    memory = AgentMemory.delete_turn(memory, initial_turn_id)
    assert AgentMemory.count_messages(memory) == 1
    assert AgentMemory.latest_message(memory).turn_id == other_turn_id

    memory = AgentMemory.delete_turn(memory, other_turn_id)
    assert AgentMemory.count_messages(memory) == 0

    assert_raise Normandy.NonExistentTurn, fn ->
      AgentMemory.delete_turn(memory, other_turn_id)
    end
  end
end
```

- [ ] **Step 2: Run the unit test to verify it fails**

Run: `mix test test/components/agent_memory_test.exs`
Expected: FAIL — `memory.entries`/`memory.head` undefined on the current map shape.

- [ ] **Step 3: Rewrite the AgentMemory module**

Replace the entire contents of `lib/normandy/components/agent_memory.ex` with:

```elixir
defmodule Normandy.Components.AgentMemory do
  @moduledoc """
  Conversation memory as a graph of parent-linked entries.

  Each message is an `AgentMemory.Entry` carrying its own `id` and a `parent_id`
  link to the prior entry on its branch. A linear conversation is a degenerate
  single-parent chain: `head` points at the most-recent entry, and walking
  `parent_id` back to a root reproduces the conversation. Branching is opt-in via
  `fork/2`.

  `history/1` reconstructs the active branch in chronological order — output
  identical to the previous linear implementation.
  """

  alias Normandy.Components.AgentMemory.Entry
  alias Normandy.Components.Message
  alias Normandy.Components.BaseIOSchema

  defstruct entries: %{}, head: nil, current_turn_id: nil, max_messages: nil

  @type t :: %__MODULE__{
          entries: %{String.t() => Entry.t()},
          head: String.t() | nil,
          current_turn_id: String.t() | nil,
          max_messages: pos_integer() | nil
        }

  @spec new_memory(pos_integer() | nil) :: t()
  def new_memory(max_messages \\ nil) do
    %__MODULE__{entries: %{}, head: nil, current_turn_id: nil, max_messages: max_messages}
  end

  @spec initialize_turn(t()) :: t()
  def initialize_turn(%__MODULE__{} = memory) do
    %{memory | current_turn_id: UUID.uuid4()}
  end

  @spec get_current_turn_id(t()) :: String.t() | nil
  def get_current_turn_id(%__MODULE__{current_turn_id: id}), do: id

  @spec add_message(t(), String.t(), term()) :: t()
  def add_message(%__MODULE__{} = memory, role, content) do
    memory = if memory.current_turn_id == nil, do: initialize_turn(memory), else: memory

    id = UUID.uuid4()

    entry = %Entry{
      id: id,
      parent_id: memory.head,
      turn_id: memory.current_turn_id,
      role: role,
      content: content
    }

    %{memory | entries: Map.put(memory.entries, id, entry), head: id}
    |> enforce_max_messages()
  end

  @doc "The active branch `head -> root`, returned chronological (oldest -> newest)."
  @spec entry_chain(t()) :: [Entry.t()]
  def entry_chain(%__MODULE__{} = memory) do
    memory |> chain_newest_first() |> Enum.reverse()
  end

  @doc "The active branch as `%Message{}` structs, chronological."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{} = memory) do
    memory |> entry_chain() |> Enum.map(&entry_to_message/1)
  end

  @doc "The newest message (the `head` entry), or nil when empty."
  @spec latest_message(t()) :: Message.t() | nil
  def latest_message(%__MODULE__{head: nil}), do: nil

  def latest_message(%__MODULE__{head: head, entries: entries}) do
    case Map.get(entries, head) do
      nil -> nil
      %Entry{} = entry -> entry_to_message(entry)
    end
  end

  @spec history(t()) :: [%{role: String.t(), content: String.t() | list()}]
  def history(%__MODULE__{} = memory) do
    memory
    |> messages()
    |> Enum.map(fn %Message{role: role, content: content} ->
      %{role: role, content: BaseIOSchema.to_json(content)}
    end)
  end

  @spec count_messages(t()) :: non_neg_integer()
  def count_messages(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc "Move `head` to `from_entry_id`; subsequent appends branch from there."
  @spec fork(t(), String.t()) :: {:ok, t()} | {:error, :no_such_entry}
  def fork(%__MODULE__{} = memory, from_entry_id) do
    case Map.get(memory.entries, from_entry_id) do
      nil -> {:error, :no_such_entry}
      %Entry{} -> {:ok, %{memory | head: from_entry_id}}
    end
  end

  @spec entries(t()) :: %{String.t() => Entry.t()}
  def entries(%__MODULE__{entries: entries}), do: entries

  @spec get_entry(t(), String.t()) :: Entry.t() | nil
  def get_entry(%__MODULE__{entries: entries}, id), do: Map.get(entries, id)

  @spec delete_turn(t(), String.t()) :: t()
  def delete_turn(%__MODULE__{} = memory, turn_id) do
    deleted =
      for {id, %Entry{turn_id: ^turn_id}} <- memory.entries, into: MapSet.new(), do: id

    if MapSet.size(deleted) == 0 do
      raise Normandy.NonExistentTurn, value: turn_id
    end

    entries =
      memory.entries
      |> Enum.reject(fn {id, _entry} -> MapSet.member?(deleted, id) end)
      |> Map.new(fn {id, entry} ->
        {id, %{entry | parent_id: surviving_ancestor(entry.parent_id, memory.entries, deleted)}}
      end)

    head = surviving_ancestor(memory.head, memory.entries, deleted)

    %{memory | entries: entries, head: head}
  end

  @spec dump(t()) :: String.t()
  def dump(%__MODULE__{} = memory) do
    adapter = Application.get_env(:normandy, :adapter, Poison)

    encoded_entries =
      for {_id, %Entry{} = e} <- memory.entries do
        %{
          id: e.id,
          parent_id: e.parent_id,
          turn_id: e.turn_id,
          role: e.role,
          content: encode_content(e.content)
        }
      end

    adapter.encode!(%{
      version: 1,
      max_messages: memory.max_messages,
      current_turn_id: memory.current_turn_id,
      head: memory.head,
      entries: encoded_entries
    })
  end

  @spec load(String.t()) :: t()
  def load(dump) do
    adapter = Application.get_env(:normandy, :adapter, Poison)
    loaded = adapter.decode!(dump, keys: :atoms)

    entries =
      loaded.entries
      |> Enum.map(fn e ->
        {e.id,
         %Entry{
           id: e.id,
           parent_id: e.parent_id,
           turn_id: e.turn_id,
           role: e.role,
           content: decode_content(e.content)
         }}
      end)
      |> Map.new()

    %__MODULE__{
      entries: entries,
      head: Map.get(loaded, :head),
      current_turn_id: Map.get(loaded, :current_turn_id),
      max_messages: Map.get(loaded, :max_messages)
    }
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp entry_to_message(%Entry{turn_id: turn_id, role: role, content: content}) do
    %Message{turn_id: turn_id, role: role, content: content}
  end

  # Walk head -> root, newest entry first.
  defp chain_newest_first(%__MODULE__{head: head, entries: entries}) do
    Stream.unfold(head, fn
      nil ->
        nil

      id ->
        case Map.get(entries, id) do
          nil -> nil
          %Entry{parent_id: parent_id} = entry -> {entry, parent_id}
        end
    end)
    |> Enum.to_list()
  end

  defp enforce_max_messages(%__MODULE__{max_messages: nil} = memory), do: memory

  defp enforce_max_messages(%__MODULE__{max_messages: 0} = memory) do
    %{memory | entries: %{}, head: nil}
  end

  defp enforce_max_messages(%__MODULE__{max_messages: max} = memory) do
    chain = chain_newest_first(memory)

    if length(chain) <= max do
      memory
    else
      kept = Enum.take(chain, max)
      dropped = Enum.drop(chain, max)
      oldest_kept = List.last(kept)

      entries =
        dropped
        |> Enum.reduce(memory.entries, fn %Entry{id: id}, acc -> Map.delete(acc, id) end)
        |> Map.update!(oldest_kept.id, fn entry -> %{entry | parent_id: nil} end)

      %{memory | entries: entries}
    end
  end

  # Nearest non-deleted id walking up parent links; nil if none survives.
  defp surviving_ancestor(nil, _entries, _deleted), do: nil

  defp surviving_ancestor(id, entries, deleted) do
    if MapSet.member?(deleted, id) do
      case Map.get(entries, id) do
        %Entry{parent_id: parent_id} -> surviving_ancestor(parent_id, entries, deleted)
        nil -> nil
      end
    else
      id
    end
  end

  defp encode_content(content) when is_struct(content) do
    %{type: to_string(content.__struct__), data: content}
  end

  defp encode_content(content), do: %{type: "raw", data: content}

  defp decode_content(%{type: "raw", data: data}), do: data

  defp decode_content(%{type: type, data: data}) do
    mod = String.to_existing_atom(type)
    struct(mod, data)
  end
end
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `mix test test/components/agent_memory_test.exs`
Expected: PASS (all AgentMemory tests). The full suite is still RED here — the two `rebuild_memory*` bare-map constructions next.

- [ ] **Step 5: Migrate `window_manager.ex` + `summarizer.ex` bare-map constructions**

In `lib/normandy/context/window_manager.ex`, replace `rebuild_memory/2`'s bare-map construction. Change:

```elixir
    # Start with empty memory and properly add messages using AgentMemory.add_message
    memory = %{
      max_messages: max_messages,
      history: [],
      current_turn_id: turn_id
    }
```

to:

```elixir
    # Start from a fresh entry-graph memory, preserving the active turn id so the
    # rebuilt entries stay grouped exactly as before.
    memory = %{AgentMemory.new_memory(max_messages) | current_turn_id: turn_id}
```

In `lib/normandy/context/summarizer.ex`, replace the same construction in
`rebuild_memory_with_summary/4`. Change:

```elixir
    # Start with empty memory and properly add messages using AgentMemory.add_message
    # This ensures content is stored correctly regardless of type
    memory = %{
      max_messages: max_messages,
      history: [],
      current_turn_id: turn_id
    }
```

to:

```elixir
    # Start from a fresh entry-graph memory, preserving the active turn id.
    memory = %{AgentMemory.new_memory(max_messages) | current_turn_id: turn_id}
```

(Both files already alias `Normandy.Components.AgentMemory`.)

- [ ] **Step 6: Run the full suite (parity proof)**

Run: `mix format && mix compile --warnings-as-errors --force && mix test`
Expected: PASS — full suite green at baseline. If any end-to-end test regresses, the entry-graph rewrite changed observable behavior — STOP and reconcile before committing.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/components/agent_memory.ex test/components/agent_memory_test.exs \
        lib/normandy/context/window_manager.ex lib/normandy/context/summarizer.ex
git commit -m "feat(memory): rewrite AgentMemory as a parent-linked entry graph"
```

---

### Task 4: Branching tests (fork divergence)

**Files:**
- Test: `test/components/agent_memory_branching_test.exs`

- [ ] **Step 1: Write the branching test**

Create `test/components/agent_memory_branching_test.exs`:

```elixir
defmodule NormandyTest.Components.AgentMemoryBranchingTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.AgentMemory

  defp ids_in_order(memory) do
    memory |> AgentMemory.entry_chain() |> Enum.map(& &1.id)
  end

  test "fork returns {:error, :no_such_entry} for an unknown id" do
    memory = AgentMemory.new_memory() |> AgentMemory.add_message("user", %{a: 1})
    assert AgentMemory.fork(memory, "nope") == {:error, :no_such_entry}
  end

  test "fork diverges from a chosen entry; both branches stay reachable" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", %{c: "a"})
      |> AgentMemory.add_message("assistant", %{c: "b"})
      |> AgentMemory.add_message("user", %{c: "c"})

    [id_a, id_b, id_c] = ids_in_order(memory)

    {:ok, forked} = AgentMemory.fork(memory, id_b)
    forked = AgentMemory.add_message(forked, "assistant", %{c: "d"})

    assert Enum.map(AgentMemory.messages(forked), & &1.content) == [%{c: "a"}, %{c: "b"}, %{c: "d"}]

    {:ok, original} = AgentMemory.fork(forked, id_c)
    assert Enum.map(AgentMemory.messages(original), & &1.content) == [%{c: "a"}, %{c: "b"}, %{c: "c"}]

    assert AgentMemory.count_messages(forked) == 4
    assert id_a != id_b
  end
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `mix test test/components/agent_memory_branching_test.exs`
Expected: PASS (2 tests). These exercise only public API added in Task 3, so no implementation is needed.

- [ ] **Step 3: Commit**

```bash
mix format
git add test/components/agent_memory_branching_test.exs
git commit -m "test(memory): cover fork divergence and branch reachability"
```

---

### Task 5: `SessionStore` behaviour + `InMemory` impl

**Files:**
- Create: `lib/normandy/behaviours/session_store.ex`
- Create: `lib/normandy/behaviours/session_store/in_memory.ex`
- Test: `test/behaviours/session_store/in_memory_test.exs`

- [ ] **Step 1: Define the `SessionStore` behaviour**

Create `lib/normandy/behaviours/session_store.ex`:

```elixir
defmodule Normandy.Behaviours.SessionStore do
  @moduledoc """
  Contract for externalizing a session's conversation entries and turn state.

  The memory-backing half (`append_entry`, `history`, `fork`) persists the
  parent-linked entry graph keyed by `session_id`. The turn-state half
  (`save_turn_state`, `load_turn_state`) round-trips an **opaque term** — defined
  and contract-tested in Phase 3 but with no real consumer until Phase 4's
  `%TurnState{}` (suspendable turn / passivation).

  `handle` is impl-specific (a pid for `InMemory`, a table for `ETS`). Each impl
  exposes `new/0` (or `new/1`) returning a fresh handle for tests and callers.
  """

  alias Normandy.Components.AgentMemory.Entry

  @type handle :: term()
  @type session_id :: String.t()

  @callback append_entry(handle(), session_id(), Entry.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback history(handle(), session_id()) :: {:ok, [Entry.t()]} | {:error, term()}
  @callback fork(handle(), session_id(), from_entry_id :: String.t()) ::
              {:ok, session_id()} | {:error, term()}
  @callback save_turn_state(handle(), session_id(), state :: term()) :: :ok | {:error, term()}
  @callback load_turn_state(handle(), session_id()) :: {:ok, term()} | :error
end
```

- [ ] **Step 2: Write the InMemory test**

Create `test/behaviours/session_store/in_memory_test.exs`:

```elixir
defmodule Normandy.Behaviours.SessionStore.InMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory.Entry

  setup do
    {:ok, handle: InMemory.new()}
  end

  test "append_entry returns an id; history is chronological", %{handle: h} do
    {:ok, id1} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})
    {:ok, id2} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})

    assert is_binary(id1) and is_binary(id2)
    assert {:ok, entries} = InMemory.history(h, "s1")
    assert Enum.map(entries, & &1.content) == ["a", "b"]
  end

  test "history on an unknown session is empty", %{handle: h} do
    assert {:ok, []} = InMemory.history(h, "missing")
  end

  test "fork yields the ancestor chain and isolates appends", %{handle: h} do
    {:ok, _} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})
    {:ok, at} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})
    {:ok, _} = InMemory.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "c"})

    {:ok, forked} = InMemory.fork(h, "s1", at)
    assert {:ok, fe} = InMemory.history(h, forked)
    assert Enum.map(fe, & &1.content) == ["a", "b"]

    {:ok, _} = InMemory.append_entry(h, forked, %Entry{turn_id: "t", role: "assistant", content: "d"})
    assert {:ok, oe} = InMemory.history(h, "s1")
    assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
    assert {:ok, fe2} = InMemory.history(h, forked)
    assert Enum.map(fe2, & &1.content) == ["a", "b", "d"]
  end

  test "turn state round-trips an opaque term; missing is :error", %{handle: h} do
    term = {:turn, %{step: 3}, "opaque"}
    assert :ok = InMemory.save_turn_state(h, "s1", term)
    assert {:ok, ^term} = InMemory.load_turn_state(h, "s1")
    assert :error = InMemory.load_turn_state(h, "never")
  end

  test "implements the SessionStore behaviour" do
    behaviours = InMemory.module_info(:attributes)[:behaviour] || []
    assert Normandy.Behaviours.SessionStore in behaviours
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/behaviours/session_store/in_memory_test.exs`
Expected: FAIL — `Normandy.Behaviours.SessionStore.InMemory` is undefined.

- [ ] **Step 4: Implement the InMemory store**

Create `lib/normandy/behaviours/session_store/in_memory.ex`:

```elixir
defmodule Normandy.Behaviours.SessionStore.InMemory do
  @moduledoc """
  Process-backed in-memory `SessionStore` — the reference impl and default
  selection. Holds one `AgentMemory` per `session_id` plus an opaque turn-state
  map, in an `Agent`. Used for tests and library/single-node runs; not consumed by
  the turn loop in Phase 3.
  """

  @behaviour Normandy.Behaviours.SessionStore

  use Agent

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{sessions: %{}, turn_states: %{}} end)
  end

  @doc "Start a fresh store and return its handle (pid)."
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
    {:ok, pid} = start_link(opts)
    pid
  end

  @impl true
  def append_entry(pid, session_id, %Entry{} = entry) do
    Agent.get_and_update(pid, fn state ->
      memory = Map.get(state.sessions, session_id, AgentMemory.new_memory())
      {id, memory} = put_entry(memory, entry)
      {{:ok, id}, put_in(state.sessions[session_id], memory)}
    end)
  end

  @impl true
  def history(pid, session_id) do
    Agent.get(pid, fn state ->
      case Map.get(state.sessions, session_id) do
        nil -> {:ok, []}
        %AgentMemory{} = memory -> {:ok, AgentMemory.entry_chain(memory)}
      end
    end)
  end

  @impl true
  def fork(pid, session_id, from_entry_id) do
    Agent.get_and_update(pid, fn state ->
      case Map.get(state.sessions, session_id) do
        nil ->
          {{:error, :no_such_session}, state}

        %AgentMemory{} = memory ->
          case AgentMemory.fork(memory, from_entry_id) do
            {:error, reason} ->
              {{:error, reason}, state}

            {:ok, forked} ->
              new_id = UUID.uuid4()
              {{:ok, new_id}, put_in(state.sessions[new_id], forked)}
          end
      end
    end)
  end

  @impl true
  def save_turn_state(pid, session_id, term) do
    Agent.update(pid, fn state -> put_in(state.turn_states[session_id], term) end)
  end

  @impl true
  def load_turn_state(pid, session_id) do
    Agent.get(pid, fn state ->
      case Map.fetch(state.turn_states, session_id) do
        {:ok, term} -> {:ok, term}
        :error -> :error
      end
    end)
  end

  # Append an entry, minting an id and linking to the current head when absent.
  defp put_entry(%AgentMemory{} = memory, %Entry{} = entry) do
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || memory.head}
    {id, %{memory | entries: Map.put(memory.entries, id, entry), head: id}}
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/behaviours/session_store/in_memory_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
mix format
git add lib/normandy/behaviours/session_store.ex \
        lib/normandy/behaviours/session_store/in_memory.ex \
        test/behaviours/session_store/in_memory_test.exs
git commit -m "feat(memory): add SessionStore behaviour + InMemory impl"
```

---

### Task 6: `SessionStore.ETS` impl

**Files:**
- Create: `lib/normandy/behaviours/session_store/ets.ex`
- Test: `test/behaviours/session_store/ets_test.exs`

- [ ] **Step 1: Write the ETS test**

Create `test/behaviours/session_store/ets_test.exs`:

```elixir
defmodule Normandy.Behaviours.SessionStore.ETSTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore.ETS
  alias Normandy.Components.AgentMemory.Entry

  setup do
    {:ok, handle: ETS.new()}
  end

  test "append_entry returns an id; history is chronological", %{handle: h} do
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})
    assert {:ok, entries} = ETS.history(h, "s1")
    assert Enum.map(entries, & &1.content) == ["a", "b"]
  end

  test "history on an unknown session is empty", %{handle: h} do
    assert {:ok, []} = ETS.history(h, "missing")
  end

  test "fork yields the ancestor chain and isolates appends", %{handle: h} do
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "a"})
    {:ok, at} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "assistant", content: "b"})
    {:ok, _} = ETS.append_entry(h, "s1", %Entry{turn_id: "t", role: "user", content: "c"})

    {:ok, forked} = ETS.fork(h, "s1", at)
    {:ok, _} = ETS.append_entry(h, forked, %Entry{turn_id: "t", role: "assistant", content: "d"})

    assert {:ok, oe} = ETS.history(h, "s1")
    assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
    assert {:ok, fe} = ETS.history(h, forked)
    assert Enum.map(fe, & &1.content) == ["a", "b", "d"]
  end

  test "turn state round-trips an opaque term; missing is :error", %{handle: h} do
    term = {:turn, %{step: 7}}
    assert :ok = ETS.save_turn_state(h, "s1", term)
    assert {:ok, ^term} = ETS.load_turn_state(h, "s1")
    assert :error = ETS.load_turn_state(h, "never")
  end

  test "implements the SessionStore behaviour" do
    behaviours = ETS.module_info(:attributes)[:behaviour] || []
    assert Normandy.Behaviours.SessionStore in behaviours
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/behaviours/session_store/ets_test.exs`
Expected: FAIL — `Normandy.Behaviours.SessionStore.ETS` is undefined.

- [ ] **Step 3: Implement the ETS store**

Create `lib/normandy/behaviours/session_store/ets.ex`:

```elixir
defmodule Normandy.Behaviours.SessionStore.ETS do
  @moduledoc """
  ETS-backed `SessionStore` — fast, in-node. The handle is a table id; each
  session's `AgentMemory` is stored under `{:session, session_id}` and its opaque
  turn state under `{:turn_state, session_id}`. Anonymous (non-`:named_table`) so
  multiple stores coexist; not consumed by the turn loop in Phase 3.

  Reads-then-writes are not atomic across the table — adequate for the Phase 3
  contract and single-writer use. Concurrency hardening (a serializing owner) is a
  Phase 4 concern when the turn shell becomes the writer.
  """

  @behaviour Normandy.Behaviours.SessionStore

  alias Normandy.Components.AgentMemory
  alias Normandy.Components.AgentMemory.Entry

  @doc "Create a fresh ETS-backed store; returns the table id (handle)."
  @spec new(keyword()) :: :ets.tid()
  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :normandy_session_store)
    :ets.new(name, [:set, :public])
  end

  @impl true
  def append_entry(tid, session_id, %Entry{} = entry) do
    memory = lookup_memory(tid, session_id)
    id = entry.id || UUID.uuid4()
    entry = %{entry | id: id, parent_id: entry.parent_id || memory.head}
    memory = %{memory | entries: Map.put(memory.entries, id, entry), head: id}
    :ets.insert(tid, {{:session, session_id}, memory})
    {:ok, id}
  end

  @impl true
  def history(tid, session_id) do
    {:ok, tid |> lookup_memory(session_id) |> AgentMemory.entry_chain()}
  end

  @impl true
  def fork(tid, session_id, from_entry_id) do
    case :ets.lookup(tid, {:session, session_id}) do
      [] ->
        {:error, :no_such_session}

      [{_, %AgentMemory{} = memory}] ->
        case AgentMemory.fork(memory, from_entry_id) do
          {:error, reason} ->
            {:error, reason}

          {:ok, forked} ->
            new_id = UUID.uuid4()
            :ets.insert(tid, {{:session, new_id}, forked})
            {:ok, new_id}
        end
    end
  end

  @impl true
  def save_turn_state(tid, session_id, term) do
    :ets.insert(tid, {{:turn_state, session_id}, term})
    :ok
  end

  @impl true
  def load_turn_state(tid, session_id) do
    case :ets.lookup(tid, {:turn_state, session_id}) do
      [{_, term}] -> {:ok, term}
      [] -> :error
    end
  end

  defp lookup_memory(tid, session_id) do
    case :ets.lookup(tid, {:session, session_id}) do
      [{_, %AgentMemory{} = memory}] -> memory
      [] -> AgentMemory.new_memory()
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/behaviours/session_store/ets_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/normandy/behaviours/session_store/ets.ex test/behaviours/session_store/ets_test.exs
git commit -m "feat(memory): add SessionStore.ETS impl"
```

---

### Task 7: Shared `SessionStore` contract suite

Replace the two hand-rolled impl test files with one shared contract macro run against both impls — so the contract stays impl-agnostic (the design's testing strategy).

**Files:**
- Create: `test/support/session_store_contract.ex`
- Replace: `test/behaviours/session_store/in_memory_test.exs`
- Replace: `test/behaviours/session_store/ets_test.exs`

- [ ] **Step 1: Write the shared contract macro**

Create `test/support/session_store_contract.ex`:

```elixir
defmodule Normandy.SessionStoreContract do
  @moduledoc """
  Shared ExUnit contract for `Normandy.Behaviours.SessionStore` impls.

  Use in a test module that also `use ExUnit.Case`:

      use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory

  The impl must expose `new/0` returning a fresh handle.
  """

  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)

    quote bind_quoted: [impl: impl] do
      alias Normandy.Components.AgentMemory.Entry

      @store impl

      setup do
        {:ok, handle: @store.new()}
      end

      defp contract_entry(role, content), do: %Entry{turn_id: "t", role: role, content: content}

      test "append_entry returns an id; history is chronological", %{handle: h} do
        {:ok, id1} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        {:ok, id2} = @store.append_entry(h, "s1", contract_entry("assistant", "b"))

        assert is_binary(id1) and is_binary(id2)
        assert {:ok, entries} = @store.history(h, "s1")
        assert Enum.map(entries, & &1.content) == ["a", "b"]
      end

      test "history on an unknown session is empty", %{handle: h} do
        assert {:ok, []} = @store.history(h, "missing")
      end

      test "fork yields the ancestor chain and isolates appends", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        {:ok, at} = @store.append_entry(h, "s1", contract_entry("assistant", "b"))
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "c"))

        {:ok, forked} = @store.fork(h, "s1", at)
        assert {:ok, fe} = @store.history(h, forked)
        assert Enum.map(fe, & &1.content) == ["a", "b"]

        {:ok, _} = @store.append_entry(h, forked, contract_entry("assistant", "d"))
        assert {:ok, oe} = @store.history(h, "s1")
        assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
        assert {:ok, fe2} = @store.history(h, forked)
        assert Enum.map(fe2, & &1.content) == ["a", "b", "d"]
      end

      test "fork on an unknown entry errors", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        assert {:error, _} = @store.fork(h, "s1", "no-such-entry")
      end

      test "turn state round-trips an opaque term; missing is :error", %{handle: h} do
        term = {:turn, %{step: 3, calls: [:a, :b]}, "opaque"}
        assert :ok = @store.save_turn_state(h, "s1", term)
        assert {:ok, ^term} = @store.load_turn_state(h, "s1")
        assert :error = @store.load_turn_state(h, "never-saved")
      end

      test "implements the SessionStore behaviour" do
        behaviours = @store.module_info(:attributes)[:behaviour] || []
        assert Normandy.Behaviours.SessionStore in behaviours
      end
    end
  end
end
```

- [ ] **Step 2: Replace the impl test files to use the contract**

Replace the entire contents of `test/behaviours/session_store/in_memory_test.exs` with:

```elixir
defmodule Normandy.Behaviours.SessionStore.InMemoryTest do
  use ExUnit.Case, async: true
  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory
end
```

Replace the entire contents of `test/behaviours/session_store/ets_test.exs` with:

```elixir
defmodule Normandy.Behaviours.SessionStore.ETSTest do
  use ExUnit.Case, async: true
  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.ETS
end
```

- [ ] **Step 3: Run both impl test files to verify they pass**

Run: `mix test test/behaviours/session_store/`
Expected: PASS — 6 tests per impl (12 total), identical contract against both `InMemory` and `ETS`.

- [ ] **Step 4: Commit**

```bash
mix format
git add test/support/session_store_contract.ex \
        test/behaviours/session_store/in_memory_test.exs \
        test/behaviours/session_store/ets_test.exs
git commit -m "test(memory): share one SessionStore contract across InMemory + ETS"
```

---

### Task 8: `session_store` slot on `Normandy.Behaviours.Config`

**Files:**
- Modify: `lib/normandy/behaviours/config.ex` (struct, `@type`, moduledoc)
- Modify: `test/behaviours/config_test.exs` (default-bundle assertion)

- [ ] **Step 1: Update the default-bundle test to assert the new slot**

In `test/behaviours/config_test.exs`, in the `test "has all-default impl refs"`, add after the `model_catalog` assertion:

```elixir
      assert b.session_store == {Normandy.Behaviours.SessionStore.InMemory, []}
```

- [ ] **Step 2: Run the config test to verify it fails**

Run: `mix test test/behaviours/config_test.exs:32`
Expected: FAIL — `b.session_store` key missing (slot not added yet).

- [ ] **Step 3: Add the `session_store` slot to `Config`**

In `lib/normandy/behaviours/config.ex`:

(a) Add the alias near the other behaviour aliases:

```elixir
  alias Normandy.Behaviours.SessionStore
```

(b) Add `session_store: ref()` to the `@type t` (after `model_catalog: ref()`).

(c) Add the default to the `defstruct` (after `model_catalog: {ModelCatalog.Static, []}`):

```elixir
            model_catalog: {ModelCatalog.Static, []},
            session_store: {SessionStore.InMemory, []}
```

(d) In the moduledoc, change the sentence "The `credential` and `model_catalog`
slots are not dispatch-path concerns and are not placed on the pipeline." to:

```
  The `credential`, `model_catalog`, and `session_store` slots are not
  dispatch-path concerns and are not placed on the pipeline. `session_store`
  selects where session entries / turn state persist; it is wired here but not yet
  consumed by the turn loop (Phase 4 reads it).
```

Do **not** change `to_pipeline/1` — it must keep ignoring the non-dispatch slots.

- [ ] **Step 4: Run the config tests to verify they pass**

Run: `mix test test/behaviours/config_test.exs`
Expected: PASS — including the unchanged `to_pipeline/1` equivalence test
(`Config.to_pipeline(nil) == Config.to_pipeline(%Config{})`).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/normandy/behaviours/config.ex test/behaviours/config_test.exs
git commit -m "feat(memory): add session_store slot to Behaviours.Config (unconsumed)"
```

---

### Task 9: CHANGELOG + version bump to 1.0.0

**Files:**
- Modify: `mix.exs:4` (`@version`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Bump the version**

In `mix.exs`, change `@version "0.7.0"` to `@version "1.0.0"`.

- [ ] **Step 2: Add the CHANGELOG entry**

In `CHANGELOG.md`, insert directly under the `## [Unreleased]` line:

```markdown
## [1.0.0] - 2026-06-01

### Added

- **Branching session memory + SessionStore (Phase 3 of the harness
  decomposition).**
  - `Normandy.Components.AgentMemory` is now a struct of parent-linked
    `AgentMemory.Entry` records (`id` + `parent_id`) instead of a linear list.
    Branching is opt-in via `fork/2`; a linear conversation is a degenerate
    single-parent chain and `history/1` output is unchanged. New accessors:
    `fork/2`, `entries/1`, `get_entry/2`, `entry_chain/1`, `messages/1`,
    `latest_message/1`.
  - `Normandy.Behaviours.SessionStore` (`append_entry/3`, `history/2`, `fork/3`,
    `save_turn_state/3`, `load_turn_state/2`) with `InMemory` (default) and `ETS`
    impls sharing one contract suite. The turn-state half round-trips an opaque
    term; its consumer (suspendable turn / passivation) lands in Phase 4. Postgres
    is deferred.
  - `session_store` slot on `Normandy.Behaviours.Config` (default
    `{SessionStore.InMemory, []}`) — selectable per-agent, not on the dispatch
    pipeline, not yet consumed by the turn loop.

### Changed

- **BREAKING:** `AgentMemory`'s struct shape and `dump/1`/`load/1` JSON format
  changed (now versioned, entry-based). Code that read the old `%{history: [...]}`
  map shape must use the public API or the new accessors. The `dump/1`/`load/1`
  format is not backward-compatible with pre-1.0 dumps.

### Notes

- Linear-conversation observable behavior is unchanged — the end-to-end suite is
  the parity oracle. Internal consumers (`base_agent` iteration counters,
  `window_manager`/`summarizer` memory rebuild) and white-box tests were migrated
  behavior-preservingly to the new accessors.
```

- [ ] **Step 3: Run the full suite + compile gate**

Run: `mix format && mix compile --warnings-as-errors --force && mix test`
Expected: PASS — full suite green; version + CHANGELOG are non-code.

- [ ] **Step 4: Commit**

```bash
git add mix.exs CHANGELOG.md
git commit -m "chore: cut 1.0.0 — branching AgentMemory + SessionStore"
```

---

## Final verification

After all tasks:

```bash
mix format
mix compile --warnings-as-errors --force
mix test
```

Expected: 0 failures; doctests at 71; new tests present (Entry, branching, SessionStore contract ×2 impls). Confirm no stray old-shape reads remain:
`grep -rn "memory\.history\|history: \[\]" lib/ test/ --include="*.ex" --include="*.exs" | grep -v "components/agent_memory"` → no output.

Then proceed to `superpowers:finishing-a-development-branch`.
