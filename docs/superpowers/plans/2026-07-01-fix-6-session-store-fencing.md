# Fix 6 — Split-Brain Fencing for Postgres + Redis, plus Mitigations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent split-brain double-writers from corrupting a shared session: a per-session monotonic **epoch**, enforced at the store (the only shared authority). `Turn.Server` acquires an epoch at start and passes it with every hot-path write; a stale writer gets `{:error, :fenced}` and stops `:normal`. Ships with three mitigations: a telemetry counter on Redis-registry evictions of dead-looking keys, a `:running` turn timeout on `Turn.Server`, and documented Horde netsplit limits.

**Architecture:**
- New **optional** `SessionStore` callbacks: `acquire_epoch/2` plus 4-arity (opts-carrying) `append_entry/4` and `save_turn_state/4`. Support detection via a `supports_epoch?/1` helper on the behaviour module (`Code.ensure_loaded?` + `function_exported?` — the same optional-callback detection idiom `Turn.Server.child_name_for/3` already uses for `SessionRegistry.child_name/2`).
- **Postgres:** `epoch` column on `normandy_sessions` (default 0) via a new `MigrationAddEpoch`; acquire = `UPDATE … SET epoch = epoch + 1 … RETURNING epoch` (with the store's existing INSERT-ON-CONFLICT get-or-create idiom so a not-yet-existing session row is handled); fenced writes compare the epoch under the existing transaction/`FOR UPDATE` structure.
- **Redis:** epoch in a per-session key (`{sid}` hash-tagged so it shares a Cluster slot with the stream/meta keys) via `INCR`; fenced writes go through small Lua compare-and-write scripts returning a `"FENCED"` sentinel the client maps to `{:error, :fenced}`.
- **Turn.Server:** acquires the epoch in `init/1` (covers register, rehydrate, and Tier-2 thin starts — all go through `init`), carries it in `Data`, threads it through `append_to_store/3` and `persist_turn_state/2`; on `{:error, :fenced}` it logs a warning, replies `{:error, :fenced}` to any waiting caller, and stops `:normal` **without persisting anything further**.
- `save_config_template` stays **unfenced by design**: it is written by `Turn.Session` during bootstrap, before any server (and thus any epoch) exists; it is config-level, not turn-mutating.
- Default for non-supporting stores (ETS/InMemory/Mnesia): the server carries `epoch: nil` and uses the existing 3-arity writes — the spec's "epoch 0, writes unchecked" default. ETS/InMemory are node-local (duplicate servers write to *different* stores; fencing is meaningless). Mnesia is deferred with a documented rationale in its moduledoc.
- **No new `Turn.step/2` effect is introduced.** The turn timeout feeds the *existing* `{:llm_error, reason}` event; store writes only happen in `Turn.Server` (Driver/Inline no-op `{:persist, _}`/`{:append_message, _, _}` store-wise), so the three-interpreter wiring constraint is satisfied with zero Driver/Inline changes.

**Tech Stack:** Elixir, ExUnit, Ecto/Postgrex (optional dep), Redix + Redis Lua (optional dep), `:telemetry`, `:gen_statem`.

**Reference:** `docs/superpowers/specs/2026-07-01-critical-fixes-design.md` — "Fix 6" section and the "Decisions" table.

## Pinned interface (this plan defines it)

```elixir
# Normandy.Behaviours.SessionStore — new optional callbacks
@callback acquire_epoch(handle(), session_id()) :: {:ok, non_neg_integer()}
@callback append_entry(handle(), session_id(), Entry.t(), opts :: keyword()) ::
            {:ok, String.t()} | {:error, term()}
@callback save_turn_state(handle(), session_id(), state :: term(), opts :: keyword()) ::
            :ok | {:error, term()}
@optional_callbacks acquire_epoch: 2, append_entry: 4, save_turn_state: 4

# Support detection (public helper on the behaviour module)
Normandy.Behaviours.SessionStore.supports_epoch?(mod) :: boolean()
```

- `opts` carries `epoch: pos_integer()`. A write whose epoch no longer matches the store's current epoch returns `{:error, :fenced}` and must mutate nothing.
- `acquire_epoch/2` failures **raise** (fail-fast at server start, matching `reconstruct_config!/3`'s philosophy); the `{:ok, _}`-only success type is deliberate.
- Mitigation surface: telemetry event `[:normandy, :session_registry, :eviction]` (measurements `%{count: 1}`); `Turn.Server` opt `:turn_timeout_ms` (default `600_000`) firing a synthetic `{:llm_error, :turn_timeout}`.

## Global Constraints

- **Verified baseline** (2026-07-01, after `mix deps.get` — the lock was stale; run `mix deps.get` first if `mix test` complains about lock mismatch): `mix test` → `71 doctests, 26 properties, 1432 tests, 0 failures (128 excluded)`. All existing tests must pass at every checkpoint; per repo convention, **run `mix format` before every test run**.
- **Service-gated tests:** Postgres tests are tagged `@moduletag :postgres` and run via `mix test.postgres` (the alias sets `NORMANDY_POSTGRES=true`, runs `ecto.setup`, then `mix test --include postgres`; extra args pass through, so `mix test.postgres path/to/file.exs` works). Redis tests are tagged `@moduletag :redis` and run via `mix test.redis` (needs a reachable Redis at `:redis_url`, default `redis://localhost:6379`; connection config for Postgres is in `config/test.exs`). Tasks 3–5 and 8 require the respective service; all other tasks run under plain `mix test`.
- **Non-breaking:** `append_entry/3` and `save_turn_state/3` keep their exact signatures and behavior; the 4-arity forms and `acquire_epoch/2` are `@optional_callbacks`. ETS/InMemory/Mnesia are not modified except Mnesia's moduledoc.
- CI runs a Dialyzer gate — keep every new `@spec`/`@impl` exact; run `mix dialyzer` in the final task.
- Git: never `git add .` — add files individually. Use each task's commit message verbatim. **No AI authorship attribution** in commits (no "Generated with", no `Co-Authored-By`).
- NO placeholders anywhere: the code below is complete and compiles against the current source; copy it as written and adapt only if the surrounding file drifted.

---

### Task 1: `SessionStore` behaviour — optional epoch callbacks + `supports_epoch?/1`

**Files:**
- Modify: `lib/normandy/behaviours/session_store.ex`
- Create: `test/behaviours/session_store_epoch_support_test.exs`

**Interfaces:**
- Produces: the pinned optional callbacks and `Normandy.Behaviours.SessionStore.supports_epoch?/1`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

Create `test/behaviours/session_store_epoch_support_test.exs`:

```elixir
defmodule Normandy.Behaviours.SessionStoreEpochSupportTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.SessionStore

  defmodule FakeEpochStore do
    def acquire_epoch(_handle, _sid), do: {:ok, 1}
  end

  test "supports_epoch? is true iff the module exports acquire_epoch/2" do
    assert SessionStore.supports_epoch?(FakeEpochStore)
    refute SessionStore.supports_epoch?(Normandy.Behaviours.SessionStore.InMemory)
    refute SessionStore.supports_epoch?(Normandy.Behaviours.SessionStore.ETS)
    refute SessionStore.supports_epoch?(Normandy.Behaviours.SessionStore.Mnesia)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix format && mix test test/behaviours/session_store_epoch_support_test.exs`
Expected: FAIL — `SessionStore.supports_epoch?/1` is undefined (`UndefinedFunctionError`).

- [ ] **Step 3: Implement**

In `lib/normandy/behaviours/session_store.ex`, add the following AFTER the existing `list_resumable` callback (keep everything else unchanged), and append a short paragraph to the `@moduledoc` explaining fencing:

```elixir
  @doc """
  Atomically increments and returns the per-session **fencing epoch** (Fix 6,
  split-brain fencing).

  Optional: only distributed, shared stores implement it (Postgres, Redis). A
  `Turn.Server` acquires an epoch at start and passes it to the 4-arity
  `append_entry`/`save_turn_state`; a write carrying a stale epoch returns
  `{:error, :fenced}` (and mutates nothing) — the stale server must stop, since
  a newer claimant owns the session. `save_config_template` is deliberately
  NOT fenced: `Turn.Session` writes it during bootstrap, before any server (and
  thus any epoch) exists. Detect support with `supports_epoch?/1`; acquire
  failures raise (fail-fast at server start).
  """
  @callback acquire_epoch(handle(), session_id()) :: {:ok, non_neg_integer()}

  @doc "Epoch-checked `append_entry/3`: `opts[:epoch]` stale → `{:error, :fenced}`."
  @callback append_entry(handle(), session_id(), Entry.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Epoch-checked `save_turn_state/3`: `opts[:epoch]` stale → `{:error, :fenced}`."
  @callback save_turn_state(handle(), session_id(), state :: term(), opts :: keyword()) ::
              :ok | {:error, term()}

  @optional_callbacks acquire_epoch: 2, append_entry: 4, save_turn_state: 4

  @doc """
  Whether `mod` supports split-brain fencing (exports `acquire_epoch/2`).

  Callers holding an epoch use the 4-arity `append_entry`/`save_turn_state`;
  when this returns `false`, callers use the 3-arity writes (the "epoch 0,
  writes unchecked" default — ETS/InMemory are node-local, Mnesia is deferred).
  Mirrors the `function_exported?`-based optional-callback detection used for
  `SessionRegistry.child_name/2` (see `Turn.Server.child_name_for/3`), with an
  explicit `Code.ensure_loaded?/1` so a not-yet-loaded store module is never
  misread as unsupporting.
  """
  @spec supports_epoch?(module()) :: boolean()
  def supports_epoch?(mod) when is_atom(mod),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, :acquire_epoch, 2)
```

- [ ] **Step 4: Run the test**

Run: `mix format && mix test test/behaviours/session_store_epoch_support_test.exs`
Expected: PASS (1 test, 0 failures).

- [ ] **Step 5: Full suite**

Run: `mix test`
Expected: 0 failures (baseline + 1 new test).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/behaviours/session_store.ex
git add test/behaviours/session_store_epoch_support_test.exs
git commit -m "feat(session-store): optional epoch-fencing callbacks + supports_epoch?/1"
```

---

### Task 2: Contract-test additions — fence semantics + unfenced default

**Files:**
- Modify: `test/support/session_store_contract.ex`

**Interfaces:**
- Produces: shared contract tests, generated conditionally at test-module compile time via `supports_epoch?/1`. Supporting stores (Postgres/Redis, Tasks 4–5) get acquire/fence tests — including the **two-writer** test and the **unfenced `save_config_template`** test; non-supporting stores (ETS/InMemory/Mnesia) get the unfenced-default test. The two-writer test doubles as the Redis Lua compare-and-write unit when run under `:redis`.

- [ ] **Step 1: Add the contract tests**

In `test/support/session_store_contract.ex`, inside the `quote` block, add after the final existing test (`"implements the SessionStore behaviour"`):

```elixir
      # --- Fix 6: split-brain fencing (epoch) contract ---
      #
      # Generated conditionally at compile time of the using test module: stores
      # exporting acquire_epoch/2 get the fence-semantics tests; the rest get the
      # unfenced-default test. (Until a store implements the callback, only the
      # else-branch exists for it — the fenced tests appear the moment the store
      # exports acquire_epoch/2.)
      if Normandy.Behaviours.SessionStore.supports_epoch?(@store) do
        test "acquire_epoch is monotonic per session and independent across sessions",
             %{handle: h} do
          {:ok, e1} = @store.acquire_epoch(h, "epoch-a")
          {:ok, e2} = @store.acquire_epoch(h, "epoch-a")
          {:ok, f1} = @store.acquire_epoch(h, "epoch-b")
          {:ok, f2} = @store.acquire_epoch(h, "epoch-b")

          assert e1 >= 1
          assert e2 == e1 + 1
          # epoch-b's counter is independent of epoch-a's churn
          assert f2 == f1 + 1
        end

        test "two writers: the second acquire_epoch fences the first's subsequent writes",
             %{handle: h} do
          sid = "epoch-fence"

          # Writer A claims the session and writes successfully…
          {:ok, a} = @store.acquire_epoch(h, sid)
          assert {:ok, _} = @store.append_entry(h, sid, contract_entry("user", "from-a"), epoch: a)
          assert :ok = @store.save_turn_state(h, sid, {:state, :a}, epoch: a)

          # …then writer B claims it. A's epoch is now stale.
          {:ok, b} = @store.acquire_epoch(h, sid)
          assert b == a + 1

          assert {:error, :fenced} =
                   @store.append_entry(h, sid, contract_entry("user", "stale-a"), epoch: a)

          assert {:error, :fenced} = @store.save_turn_state(h, sid, {:state, :stale}, epoch: a)

          # The fenced writes mutated nothing.
          assert {:ok, entries} = @store.history(h, sid)
          assert Enum.map(entries, & &1.content) == ["from-a"]
          assert {:ok, {:state, :a}} = @store.load_turn_state(h, sid)

          # B (current epoch) writes fine.
          assert {:ok, _} = @store.append_entry(h, sid, contract_entry("user", "from-b"), epoch: b)
          assert :ok = @store.save_turn_state(h, sid, {:state, :b}, epoch: b)
          assert {:ok, entries2} = @store.history(h, sid)
          assert Enum.map(entries2, & &1.content) == ["from-a", "from-b"]
          assert {:ok, {:state, :b}} = @store.load_turn_state(h, sid)
        end

        test "save_config_template stays unfenced (bootstrap writes carry no epoch)",
             %{handle: h} do
          sid = "epoch-tmpl"
          {:ok, _} = @store.acquire_epoch(h, sid)
          {:ok, _} = @store.acquire_epoch(h, sid)

          # Turn.Session writes the template during bootstrap, before any
          # server/epoch exists — it must succeed regardless of epoch churn.
          assert :ok =
                   @store.save_config_template(h, sid, %{template_id: "k", resume_policy: :lazy})

          assert {:ok, %{template_id: "k"}} = @store.load_config_template(h, sid)
        end
      else
        test "stores without acquire_epoch are unfenced: plain 3-arity writes always apply",
             %{handle: h} do
          refute Normandy.Behaviours.SessionStore.supports_epoch?(@store)

          # Default epoch semantics (epoch 0, unchecked): the 3-arity writes used
          # by unfenced callers succeed with no epoch bookkeeping.
          assert {:ok, _} = @store.append_entry(h, "unfenced", contract_entry("user", "x"))
          assert :ok = @store.save_turn_state(h, "unfenced", :s)
        end
      end
```

- [ ] **Step 2: Run the non-service store suites**

Run: `mix format && mix test test/behaviours/session_store/ets_test.exs test/behaviours/session_store/in_memory_test.exs test/behaviours/session_store/mnesia_test.exs`
Expected: PASS — each of the three suites gains exactly one new test (`"stores without acquire_epoch are unfenced…"`), 0 failures. No store supports epochs yet, so no fenced test is generated anywhere.

- [ ] **Step 3: Full suite**

Run: `mix test`
Expected: 0 failures (+3 tests over Task 1's count).

- [ ] **Step 4: Commit**

```bash
git add test/support/session_store_contract.ex
git commit -m "test(session-store): contract coverage for epoch fencing and the unfenced default"
```

---

### Task 3: Postgres — `MigrationAddEpoch` + schema field

Requires a reachable Postgres (see Global Constraints).

**Files:**
- Create: `lib/normandy/behaviours/session_store/postgres/migration_add_epoch.ex`
- Create: `priv/test_repo/migrations/20260701000000_add_epoch.exs`
- Modify: `lib/normandy/behaviours/session_store/postgres/schemas.ex`

**Interfaces:**
- Produces: `epoch :: bigint NOT NULL DEFAULT 0` on `normandy_sessions`; `field(:epoch, :integer, default: 0)` on the `Session` schema. Mirrors the `MigrationAddResumePolicy` add-column pattern exactly (guarded module + host-callable `up/0`/`down/0` + a thin test-repo migration delegating to it).

- [ ] **Step 1: Create the library migration**

Create `lib/normandy/behaviours/session_store/postgres/migration_add_epoch.ex`:

```elixir
if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Normandy.Behaviours.SessionStore.Postgres.MigrationAddEpoch do
    @moduledoc """
    Adds the `epoch` fencing column to `normandy_sessions` (critical-fixes Fix 6,
    split-brain fencing). `Postgres.acquire_epoch/2` bumps it atomically
    (`UPDATE … SET epoch = epoch + 1 … RETURNING epoch`) and epoch-carrying
    writes compare against it under the row's `FOR UPDATE` lock, rejecting stale
    writers with `{:error, :fenced}`.

    Migration ordering for hosts: run after `Migration` (base tables),
    `MigrationAddTemplate`, and `MigrationAddResumePolicy`. Call from a host
    migration exactly like the other `Postgres.Migration*` modules.
    """
    use Ecto.Migration

    def up,
      do: alter(table(:normandy_sessions), do: add(:epoch, :bigint, default: 0, null: false))

    def down, do: alter(table(:normandy_sessions), do: remove(:epoch))
  end
end
```

- [ ] **Step 2: Create the test-repo migration**

Create `priv/test_repo/migrations/20260701000000_add_epoch.exs` (same shape as `20260617000200_add_resume_policy.exs`):

```elixir
defmodule Normandy.TestRepo.Migrations.AddEpoch do
  use Ecto.Migration

  def up, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddEpoch.up()
  def down, do: Normandy.Behaviours.SessionStore.Postgres.MigrationAddEpoch.down()
end
```

- [ ] **Step 3: Add the schema field**

In `lib/normandy/behaviours/session_store/postgres/schemas.ex`, in the `Session` schema, add after `field(:resume_policy, :string)`:

```elixir
        field(:epoch, :integer, default: 0)
```

- [ ] **Step 4: Migrate and verify existing Postgres tests still pass**

Run: `mix format && mix test.postgres test/behaviours/session_store/postgres_contract_test.exs`
Expected: PASS — the alias runs `ecto.setup` (which applies the new migration), then the contract suite. `Postgres` still does not export `acquire_epoch/2`, so the contract generates the unfenced-default test for it here; all tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/session_store/postgres/migration_add_epoch.ex
git add priv/test_repo/migrations/20260701000000_add_epoch.exs
git add lib/normandy/behaviours/session_store/postgres/schemas.ex
git commit -m "feat(session-store): postgres epoch column (MigrationAddEpoch)"
```

---

### Task 4: Postgres — `acquire_epoch/2` + epoch-fenced writes

Requires a reachable Postgres.

**Files:**
- Modify: `lib/normandy/behaviours/session_store/postgres.ex`

**Interfaces:**
- Produces: `Postgres.acquire_epoch/2`, `Postgres.append_entry/4`, `Postgres.save_turn_state/4`. The 3-arity forms delegate to the 4-arity forms with `[]` (nil epoch = unchecked), preserving their exact behavior.
- Consumes: the `epoch` column/schema field (Task 3); the contract fence tests (Task 2) turn on automatically.

- [ ] **Step 1: Implement `acquire_epoch/2` ONLY (to get a genuine red)**

In `lib/normandy/behaviours/session_store/postgres.ex`, add after `list_resumable/1`:

```elixir
    @impl true
    def acquire_epoch(repo, session_id) do
      # Atomically bump-and-return the session's fencing epoch. The row may not
      # exist yet (a server can start before any entry/turn-state write), so
      # reuse the INSERT ON CONFLICT DO NOTHING get-or-create idiom from
      # append_entry; the UPDATE … RETURNING then always hits a real row. DB
      # failures raise (fail-fast at server start, like reconstruct_config!).
      {:ok, epoch} =
        repo.transaction(fn ->
          repo.insert(%Session{session_id: session_id},
            on_conflict: :nothing,
            conflict_target: :session_id
          )

          %{rows: [[epoch]]} =
            Ecto.Adapters.SQL.query!(
              repo,
              "UPDATE normandy_sessions SET epoch = epoch + 1 WHERE session_id = $1 RETURNING epoch",
              [session_id]
            )

          epoch
        end)

      {:ok, epoch}
    end
```

- [ ] **Step 2: Run to verify the fenced contract tests appear and FAIL**

Run: `mix format && mix test.postgres test/behaviours/session_store/postgres_contract_test.exs`
Expected: FAIL — `supports_epoch?(Postgres)` is now true, so the three fence tests are generated; the two-writer test fails with `UndefinedFunctionError` (`Postgres.append_entry/4` not exported). The monotonic-acquire test and the unfenced-template test PASS.

- [ ] **Step 3: Implement the fenced writes**

Replace the existing `append_entry/3` (lines 24–66 of the current file) with the delegating pair — the transaction body is the existing one plus the epoch check right after `lock_session`:

```elixir
    @impl true
    def append_entry(repo, session_id, entry), do: append_entry(repo, session_id, entry, [])

    @impl true
    def append_entry(repo, session_id, %{__struct__: _} = entry, opts) do
      epoch = Keyword.get(opts, :epoch)

      repo.transaction(fn ->
        # Ensure the session row exists so the FOR UPDATE below always locks a real
        # row. This serializes concurrent first-appends to a new session: two callers
        # cannot both create the row and lose an entry (the standard get-or-create-
        # with-lock idiom — INSERT ON CONFLICT DO NOTHING, then SELECT FOR UPDATE).
        repo.insert(%Session{session_id: session_id},
          on_conflict: :nothing,
          conflict_target: :session_id
        )

        session = lock_session(repo, session_id)

        # Fencing (Fix 6): an epoch-carrying write must match the session's current
        # epoch, read under the same FOR UPDATE lock the write holds. A stale epoch
        # means a newer claimant ran acquire_epoch/2 — reject without mutating.
        if epoch != nil and session.epoch != epoch, do: repo.rollback(:fenced)

        id = entry.id || Ecto.UUID.generate()
        parent_id = entry.parent_id || session.head_id
        now = DateTime.utc_now()

        # Abort the transaction with {:error, reason} on a DB failure rather than
        # raising into the caller — the store contract returns error tuples, and the
        # server's fail/2 path depends on that to fail gracefully instead of crashing.
        with {:ok, _} <-
               repo.insert(%Entry{
                 id: id,
                 parent_id: parent_id,
                 turn_id: entry.turn_id,
                 role: entry.role,
                 content: encode(entry.content),
                 inserted_at: now
               }),
             {:ok, _} <-
               session
               |> Ecto.Changeset.change(head_id: id, current_turn_id: entry.turn_id)
               |> repo.update() do
          id
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, id} -> {:ok, id}
        {:error, reason} -> {:error, reason}
      end
    end
```

Replace the existing `save_turn_state/3` (lines 106–120 of the current file) with:

```elixir
    @impl true
    def save_turn_state(repo, session_id, term), do: save_turn_state(repo, session_id, term, [])

    @impl true
    def save_turn_state(repo, session_id, term, opts) do
      case Keyword.get(opts, :epoch) do
        nil -> upsert_turn_state(repo, session_id, encode(term))
        epoch -> fenced_save_turn_state(repo, session_id, encode(term), epoch)
      end
    end
```

And add the two private helpers in the `# --- Private helpers ---` section:

```elixir
    defp upsert_turn_state(repo, session_id, blob) do
      %Session{session_id: session_id}
      |> Ecto.Changeset.change(turn_state: blob)
      |> repo.insert(
        on_conflict: [set: [turn_state: blob, updated_at: DateTime.utc_now()]],
        conflict_target: :session_id
      )
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    # Fencing (Fix 6): compare-and-write under the same FOR UPDATE structure as
    # append_entry/4. The row is guaranteed to exist once an epoch was acquired
    # (acquire_epoch/2 upserts it); keep the get-or-create idiom for symmetry.
    defp fenced_save_turn_state(repo, session_id, blob, epoch) do
      repo.transaction(fn ->
        repo.insert(%Session{session_id: session_id},
          on_conflict: :nothing,
          conflict_target: :session_id
        )

        session = lock_session(repo, session_id)

        if session.epoch != epoch, do: repo.rollback(:fenced)

        case session
             |> Ecto.Changeset.change(turn_state: blob)
             |> repo.update() do
          {:ok, _} -> :ok
          {:error, reason} -> repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
```

- [ ] **Step 4: Run the contract**

Run: `mix format && mix test.postgres test/behaviours/session_store/postgres_contract_test.exs`
Expected: PASS — all contract tests including the three fence tests, 0 failures. (The unfenced-default test is no longer generated for Postgres; the suite's test list changes shape, which is expected.)

- [ ] **Step 5: Full Postgres suite (includes the Turn.Server Postgres e2e — nothing threads epochs yet, so all writes stay 3-arity and unchecked)**

Run: `mix test.postgres`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/behaviours/session_store/postgres.ex
git commit -m "feat(session-store): postgres acquire_epoch + epoch-fenced writes"
```

---

### Task 5: Redis — `acquire_epoch/2` via `INCR` + Lua compare-and-write

Requires a reachable Redis.

**Files:**
- Modify: `lib/normandy/behaviours/session_store/redis.ex`

**Interfaces:**
- Produces: `Redis.acquire_epoch/2`, `Redis.append_entry/4`, `Redis.save_turn_state/4`, private `epoch_key/2`. Fenced writes are atomic Lua scripts (plain `EVAL`, mirroring the registry's existing `@del_if_owner`/`@pexpire_if_owner` usage — no `SCRIPT LOAD` machinery); the `"FENCED"` sentinel maps to `{:error, :fenced}` client-side.

- [ ] **Step 1: Implement `acquire_epoch/2` ONLY (red first)**

In `lib/normandy/behaviours/session_store/redis.ex`, add after `list_resumable/1` (before `# --- private ---`):

```elixir
    @impl true
    def acquire_epoch({conn, ns}, session_id) do
      # Per-session fencing epoch (Fix 6): INCR is atomic and returns the new
      # value; first acquire on a fresh session yields 1. Failures raise
      # (fail-fast at server start).
      {:ok, epoch} = Redix.command(conn, ["INCR", epoch_key(ns, session_id)])
      {:ok, epoch}
    end
```

And add the key helper next to `stream_key/2`/`meta_key/2` in the private section:

```elixir
    # Hash-tagged with {sid} so it shares a Redis Cluster slot with the stream
    # and meta keys — required by the fenced-write Lua scripts, which touch the
    # epoch key and a session key in one atomic EVAL.
    defp epoch_key(ns, sid), do: "#{ns}:{#{sid}}:epoch"
```

- [ ] **Step 2: Run to verify the fenced contract tests appear and FAIL**

Run: `mix format && mix test.redis test/behaviours/session_store/redis_test.exs`
Expected: FAIL — the two-writer test fails with `UndefinedFunctionError` (`Redis.append_entry/4` not exported); the monotonic-acquire and unfenced-template tests PASS.

- [ ] **Step 3: Implement the Lua-fenced writes**

Add the two scripts as module attributes right below the `@behaviour` line (next to nothing else — the store currently has no attributes; place them above `@doc "Test/default handle…"`):

```elixir
    # --- Fix 6: split-brain fencing (epoch) ---
    #
    # Compare-and-write: each fenced write EVALs a script that compares the
    # stored epoch (KEYS[1], default 0 when absent) against the caller's
    # (ARGV[1]) and returns the sentinel "FENCED" when stale; the client maps
    # that to {:error, :fenced}. XADD ids ("<ms>-<seq>") and "OK" can never
    # collide with the sentinel. Scripts are atomic in Redis, so no interleaved
    # write can slip between the compare and the write.
    @fenced_append_script ~S"""
    local current = tonumber(redis.call("GET", KEYS[1]) or "0")
    if current ~= tonumber(ARGV[1]) then
      return "FENCED"
    end
    return redis.call("XADD", KEYS[2], "*", unpack(ARGV, 2))
    """

    @fenced_turn_state_script ~S"""
    local current = tonumber(redis.call("GET", KEYS[1]) or "0")
    if current ~= tonumber(ARGV[1]) then
      return "FENCED"
    end
    redis.call("HSET", KEYS[2], "turn_state", ARGV[2])
    return "OK"
    """
```

Add the 4-arity writes, each directly below its 3-arity sibling:

```elixir
    @impl true
    def append_entry({conn, ns} = handle, session_id, %Entry{} = entry, opts) do
      case Keyword.get(opts, :epoch) do
        nil ->
          append_entry(handle, session_id, entry)

        epoch ->
          fields = encode_entry_fields(entry)

          cmd = [
            "EVAL",
            @fenced_append_script,
            "2",
            epoch_key(ns, session_id),
            stream_key(ns, session_id),
            Integer.to_string(epoch) | fields
          ]

          case Redix.command(conn, cmd) do
            {:ok, "FENCED"} -> {:error, :fenced}
            {:ok, id} -> {:ok, id}
            {:error, reason} -> {:error, reason}
          end
      end
    end
```

```elixir
    @impl true
    def save_turn_state({conn, ns} = handle, session_id, term, opts) do
      case Keyword.get(opts, :epoch) do
        nil ->
          save_turn_state(handle, session_id, term)

        epoch ->
          cmd = [
            "EVAL",
            @fenced_turn_state_script,
            "2",
            epoch_key(ns, session_id),
            meta_key(ns, session_id),
            Integer.to_string(epoch),
            encode(term)
          ]

          case Redix.command(conn, cmd) do
            {:ok, "FENCED"} -> {:error, :fenced}
            {:ok, "OK"} -> wait(handle)
            {:error, reason} -> {:error, reason}
          end
      end
    end
```

Note: the existing `save_turn_state/3` head is `def save_turn_state({conn, ns} = handle, …)` — the new /4 clause is a separate function (different arity), so no clause-grouping issue; keep each /4 adjacent to its /3 for readability.

- [ ] **Step 4: Run the contract (this IS the Lua compare-and-write unit test)**

Run: `mix format && mix test.redis test/behaviours/session_store/redis_test.exs`
Expected: PASS — all contract tests including the three fence tests, 0 failures.

- [ ] **Step 5: Full Redis suite**

Run: `mix test.redis`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/behaviours/session_store/redis.ex
git commit -m "feat(session-store): redis acquire_epoch + Lua compare-and-write fencing"
```

---

### Task 6: `Turn.Server` — acquire the epoch at start; fenced write ⇒ warn + stop `:normal`

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex`
- Create: `test/agents/turn/server_fencing_test.exs`

**Interfaces:**
- Produces: `Data.epoch :: nil | pos_integer()` (nil = unfenced default, the spec's "epoch 0, writes unchecked"); epoch threading through `append_to_store/3` and `persist_turn_state/2`; `fenced_stop/1` (Logger.warning + reply `{:error, :fenced}` + `{:stop, :normal, _}`, **no further persists**).
- Consumes: `SessionStore.supports_epoch?/1` (Task 1). Works against any store; the test uses a local `EpochStore` double, so this task needs no services. All three interpreters remain wired: no new `Turn.step/2` effect is introduced (Driver/Inline untouched).

- [ ] **Step 1: Write the failing tests**

Create `test/agents/turn/server_fencing_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerFencingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Normandy.Agents.Turn

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # A SessionStore double that supports epochs: wraps InMemory and keeps a
  # per-session epoch counter in an Agent. 4-arity writes compare the caller's
  # epoch against the counter; stale → {:error, :fenced} (and no mutation).
  defmodule EpochStore do
    @moduledoc false
    @behaviour Normandy.Behaviours.SessionStore
    alias Normandy.Behaviours.SessionStore.InMemory

    def new do
      {:ok, epochs} = Agent.start_link(fn -> %{} end)
      {InMemory.new(), epochs}
    end

    @impl true
    def acquire_epoch({_inner, epochs}, sid) do
      {:ok,
       Agent.get_and_update(epochs, fn m ->
         e = Map.get(m, sid, 0) + 1
         {e, Map.put(m, sid, e)}
       end)}
    end

    @impl true
    def append_entry({inner, _}, sid, entry), do: InMemory.append_entry(inner, sid, entry)

    @impl true
    def append_entry({inner, _} = h, sid, entry, opts) do
      if stale?(h, sid, opts),
        do: {:error, :fenced},
        else: InMemory.append_entry(inner, sid, entry)
    end

    @impl true
    def save_turn_state({inner, _}, sid, t), do: InMemory.save_turn_state(inner, sid, t)

    @impl true
    def save_turn_state({inner, _} = h, sid, t, opts) do
      if stale?(h, sid, opts),
        do: {:error, :fenced},
        else: InMemory.save_turn_state(inner, sid, t)
    end

    @impl true
    def load_turn_state({inner, _}, sid), do: InMemory.load_turn_state(inner, sid)
    @impl true
    def history({inner, _}, sid), do: InMemory.history(inner, sid)
    @impl true
    def fork({inner, _}, sid, from), do: InMemory.fork(inner, sid, from)
    @impl true
    def save_config_template({inner, _}, sid, t), do: InMemory.save_config_template(inner, sid, t)
    @impl true
    def load_config_template({inner, _}, sid), do: InMemory.load_config_template(inner, sid)
    @impl true
    def list_resumable({inner, _}), do: InMemory.list_resumable(inner)

    defp stale?({_, epochs}, sid, opts),
      do: Keyword.fetch!(opts, :epoch) != Agent.get(epochs, &Map.get(&1, sid, 0))
  end

  defp base_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      tool_registry: nil
    }
  end

  defp handlers_returning(content) do
    %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: content, tool_calls: nil} end
    }
  end

  test "the server acquires an epoch at start and threads it through hot-path writes" do
    store = EpochStore.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-epoch",
        config: base_config(),
        store: {EpochStore, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers_returning("hi")
      )

    # init acquired epoch 1 (the double's counter moved on start).
    {_inner, epochs} = store
    assert Agent.get(epochs, &Map.get(&1, "s-epoch")) == 1

    # Epoch-checked writes succeed while the epoch is current (a mismatch or an
    # unthreaded epoch would fence / crash on Keyword.fetch!).
    assert {:ok, %Resp{content: "hi"}} = Turn.Server.run(srv, "hello")
    assert {:ok, %Turn.State{status: :stopped}} = EpochStore.load_turn_state(store, "s-epoch")
    assert {:ok, entries} = EpochStore.history(store, "s-epoch")
    assert Enum.map(entries, & &1.role) == ["user", "assistant"]
  end

  test "a fenced write replies {:error, :fenced}, logs a warning, and stops :normal" do
    store = EpochStore.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-fenced",
        config: base_config(),
        store: {EpochStore, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers_returning("never")
      )

    # A newer claimant bumps the epoch behind the running server's back.
    {:ok, 2} = EpochStore.acquire_epoch(store, "s-fenced")

    ref = Process.monitor(srv)

    log =
      capture_log(fn ->
        assert {:error, :fenced} = Turn.Server.run(srv, "hello")
        assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
      end)

    assert log =~ "fenced"

    # The stale server persisted NOTHING after the fence (no user entry, no
    # terminal turn state) — a newer claimant owns the session.
    assert {:ok, []} = EpochStore.history(store, "s-fenced")
    assert :error = EpochStore.load_turn_state(store, "s-fenced")
  end

  test "stores without acquire_epoch keep the unfenced 3-arity write path" do
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-unfenced",
        config: base_config(),
        store: {Normandy.Behaviours.SessionStore.InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers_returning("ok")
      )

    assert {:ok, %Resp{content: "ok"}} = Turn.Server.run(srv, "hello")

    assert {:ok, %Turn.State{status: :stopped}} =
             Normandy.Behaviours.SessionStore.InMemory.load_turn_state(store, "s-unfenced")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix format && mix test test/agents/turn/server_fencing_test.exs`
Expected: FAIL — test 1 fails at `Agent.get(epochs, …) == 1` (the server never calls `acquire_epoch`, so the counter is `nil`); test 2 fails because `run/2` returns `{:ok, %Resp{}}` instead of `{:error, :fenced}`. Test 3 passes (existing behavior).

- [ ] **Step 3: Implement in `lib/normandy/agents/turn/server.ex`**

3a. Below `alias Normandy.Components.ToolCall`, add:

```elixir
  require Logger
```

3b. In the `Data` defstruct, add after `resume_policy: :lazy`:

```elixir
              epoch: nil
```

(i.e. the field list ends `…, template_provider: nil, resume_policy: :lazy, epoch: nil`.)

3c. In `init/1`, after the `resume_policy` assignment and before `data = %Data{…}`, add:

```elixir
    epoch = maybe_acquire_epoch(store, session_id)
```

and add `epoch: epoch` to the `%Data{}` construction (e.g. after `idle_timeout_ms:`).

3d. Add the acquisition helper next to `load_turn_state/2`:

```elixir
  # Fix 6: claim the session by bumping its store epoch when the store supports
  # fencing. `nil` (unsupported store) selects the unfenced 3-arity writes — the
  # contract's "epoch 0, writes unchecked" default. Acquire failures raise:
  # fail-fast at server start, like reconstruct_config!/3.
  defp maybe_acquire_epoch({mod, handle}, sid) do
    if Normandy.Behaviours.SessionStore.supports_epoch?(mod) do
      {:ok, epoch} = mod.acquire_epoch(handle, sid)
      epoch
    else
      nil
    end
  end
```

3e. Replace `persist_turn_state/2` and `append_to_store/3` (currently lines 410–422) with the epoch-dispatching versions:

```elixir
  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid, epoch: epoch}, turn_state) do
    case epoch do
      nil -> mod.save_turn_state(handle, sid, turn_state)
      e -> mod.save_turn_state(handle, sid, turn_state, epoch: e)
    end
  end

  defp append_to_store(%Data{store: {mod, handle}, session_id: sid, epoch: epoch}, role, content) do
    entry = %Normandy.Components.AgentMemory.Entry{turn_id: "live", role: role, content: content}

    result =
      case epoch do
        nil -> mod.append_entry(handle, sid, entry)
        e -> mod.append_entry(handle, sid, entry, epoch: e)
      end

    case result do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
```

3f. Add the fenced-stop helper next to `fail/2`:

```elixir
  # Fix 6: a fenced write means a newer claimant acquired this session's epoch.
  # Reply (if a caller is waiting), warn, and stop :normal WITHOUT persisting
  # anything further — the newer server owns the store now. reply/2 is a no-op
  # when pending_reply is nil (eager resume / already-replied finalize).
  defp fenced_stop(data) do
    Logger.warning(
      "Turn.Server #{inspect(data.session_id)}: store write fenced by a newer epoch " <>
        "(ours: #{inspect(data.epoch)}); stopping — a newer claimant owns this session"
    )

    reply(data, {:error, :fenced})
    {:stop, :normal, %{data | pending_reply: nil}}
  end
```

3g. In `interpret/2`, extend the `{:append_message, …}` and `{:persist, …}` clauses with a `:fenced` branch (before the generic error branch):

```elixir
      {:append_message, role, content} ->
        config = data.handlers.append.(data.config, role, content)

        case append_to_store(data, role, content) do
          :ok -> interpret(rest, %{data | config: config})
          {:error, :fenced} -> fenced_stop(%{data | config: config})
          {:error, reason} -> fail(%{data | config: config}, {:persist_failed, reason})
        end

      {:persist, turn_state} ->
        case persist_turn_state(data, turn_state) do
          :ok -> interpret(rest, data)
          {:error, :fenced} -> fenced_stop(data)
          {:error, reason} -> fail(data, {:persist_failed, reason})
        end
```

3h. Replace the `{:finalize, value}` and `{:fail, reason}` clauses — the terminal-marker persist stays best-effort for ordinary errors, but `:fenced` stops the server after the reply:

```elixir
      {:finalize, value} ->
        # Persist the terminal (:stopped) turn state so the resume reaper can tell a
        # completed session from a mid-turn one. Best-effort: the turn already
        # succeeded, so a failed marker-persist must not fail it — EXCEPT :fenced,
        # which means a newer claimant owns the session: reply, then stop.
        persisted = persist_turn_state(data, data.turn_state)
        reply(data, {:ok, value})

        case persisted do
          {:error, :fenced} -> fenced_stop(%{data | pending_reply: nil})
          _ -> {:next_state, :idle, %{data | pending_reply: nil}, idle_timeout(data)}
        end

      {:fail, reason} ->
        # Persist the terminal (:failed) turn state (best-effort) for the same reason.
        persisted = persist_turn_state(data, data.turn_state)
        reply(data, {:error, reason})

        case persisted do
          {:error, :fenced} -> fenced_stop(%{data | pending_reply: nil})
          _ -> {:next_state, :idle, %{data | pending_reply: nil}, idle_timeout(data)}
        end
```

3i. In the `:idle` `{:call, from}` handler, add a `:fenced` branch to the `persist_user_message` case (set `pending_reply` first so `fenced_stop`'s reply reaches the caller):

```elixir
    case persist_user_message(data, config, user_input) do
      :ok ->
        state =
          Turn.new(
            max_iterations: config.max_tool_iterations,
            response_model: BaseAgent.turn_response_model(config),
            output_schema: config.output_schema
          )

        data = %{data | config: config, pending_reply: from}
        {state, effects} = Turn.step(state, :start)
        interpret(effects, %{data | turn_state: state})

      {:error, :fenced} ->
        fenced_stop(%{data | config: config, pending_reply: from})

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, {:persist_failed, reason}}}]}
    end
```

- [ ] **Step 4: Run the tests**

Run: `mix format && mix test test/agents/turn/server_fencing_test.exs`
Expected: PASS (3 tests, 0 failures).

- [ ] **Step 5: Full suite (all existing server/session/reaper tests must be unaffected — their stores don't export `acquire_epoch/2`)**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 6: Full Postgres + Redis suites (now the e2e server tests DO thread epochs; single-writer flows must stay green)**

Run: `mix test.postgres && mix test.redis`
Expected: 0 failures in both.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/agents/turn/server.ex
git add test/agents/turn/server_fencing_test.exs
git commit -m "feat(turn): server acquires store epoch; fenced write stops the server"
```

---

### Task 7: `Turn.Server` — `:running` turn timeout (mitigation b)

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex`
- Modify: `lib/normandy/agents/turn/session.ex`
- Create: `test/agents/turn/server_turn_timeout_test.exs`

**Interfaces:**
- Produces: server opt `:turn_timeout_ms` (default `600_000` — generous for slow LLM calls and long tool runs), carried as `Data.turn_timeout_ms`; `Data.task_pid` (so the wedged task can be killed); a `:state_timeout` armed on every entry to `:running` (each blocking effect gets a fresh deadline — the timer re-arms per `spawn_task`, exactly like `:awaiting_approval`'s `approval_expiry` pattern), firing a synthetic `{:llm_error, :turn_timeout}` into the FSM (an **existing** core event — `Turn.step/2` already maps it to `:failed` + `{:fail, reason}`; no interpreter wiring needed). Stale-message drop clauses so a result the killed task managed to send never crashes the server. `Turn.Session` passes `:turn_timeout_ms` through.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/turn/server_turn_timeout_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerTurnTimeoutTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory

  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  defp base_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      tool_registry: nil
    }
  end

  test "a wedged :running turn fails with :turn_timeout, persists terminal :failed, and the server survives" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    # Fake slow LLM (test double): the first call blocks far past the deadline;
    # a later call answers fast — proving the server recovered to :idle.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    call_llm = fn _c, _s, _r ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        0 ->
          Process.sleep(5_000)
          %Resp{content: "never", tool_calls: nil}

        _ ->
          %Resp{content: "recovered", tool_calls: nil}
      end
    end

    handlers = %{Normandy.Agents.BaseAgent.non_streaming_handlers() | call_llm: call_llm}

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s-turn-timeout",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        turn_timeout_ms: 50
      )

    log =
      capture_log(fn ->
        assert {:error, :turn_timeout} = Turn.Server.run(srv, "hello")
      end)

    assert log =~ "turn_timeout"

    assert {:ok, %Turn.State{status: :failed}} =
             InMemory.load_turn_state(store, "s-turn-timeout")

    # The server returned to :idle and serves the next turn (also exercises the
    # stale-task guards: nothing from the killed first task crashes it).
    assert {:ok, %Resp{content: "recovered"}} = Turn.Server.run(srv, "again")
  end

  test "turn_timeout_ms defaults to 600_000 and is configurable per server" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: "x", tool_calls: nil} end
    }

    base_opts = [
      config: base_config(),
      store: {InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
      handlers: handlers
    ]

    {:ok, srv1} = Turn.Server.start_link([session_id: "s-default-to"] ++ base_opts)
    {_state, data1} = :sys.get_state(srv1)
    assert data1.turn_timeout_ms == 600_000

    {:ok, srv2} =
      Turn.Server.start_link([session_id: "s-custom-to", turn_timeout_ms: 123] ++ base_opts)

    {_state, data2} = :sys.get_state(srv2)
    assert data2.turn_timeout_ms == 123
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix format && mix test test/agents/turn/server_turn_timeout_test.exs`
Expected: FAIL — test 1: `run/2` returns `{:ok, %Resp{content: "never"}}` after ~5s instead of `{:error, :turn_timeout}`; test 2: `KeyError` (no `turn_timeout_ms` field on `Data`).

- [ ] **Step 3: Implement in `lib/normandy/agents/turn/server.ex`**

3a. `Data` defstruct — extend two fields (append after `task_ref: nil` and after `epoch: nil` respectively):

```elixir
              task_pid: nil,
```
```elixir
              turn_timeout_ms: 600_000
```

3b. `init/1` — in the `%Data{}` construction, add after `idle_timeout_ms:`:

```elixir
      turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, 600_000),
```

3c. `spawn_task/2` — arm the watchdog and remember the pid; replace the final return line with:

```elixir
    {:next_state, :running, %{data | task_ref: ref, task_pid: pid},
     {:state_timeout, data.turn_timeout_ms, :turn_timeout}}
```

3d. Clear `task_pid` wherever `task_ref` is cleared today — in the two `:running` task-result clauses and the `:DOWN` clause, change `task_ref: nil` to `task_ref: nil, task_pid: nil` (three occurrences).

3e. Add the timeout handler directly after the `:approval_expiry` clause (mirroring its shape):

```elixir
  # :running watchdog (Fix 6 mitigation): a turn stuck in a blocking effect past
  # the deadline (wedged LLM call, hung tool, duplicate split-brain server) is
  # failed with a synthetic {:llm_error, :turn_timeout} instead of hanging
  # forever. Kill and demonitor the task first; anything it managed to send
  # before dying is dropped by the stale-message clauses below.
  def handle_event(:state_timeout, :turn_timeout, :running, data) do
    Logger.warning(
      "Turn.Server #{inspect(data.session_id)}: turn exceeded #{data.turn_timeout_ms}ms " <>
        "in :running; failing with :turn_timeout"
    )

    if is_reference(data.task_ref), do: Process.demonitor(data.task_ref, [:flush])
    if is_pid(data.task_pid), do: Process.exit(data.task_pid, :kill)

    {state, effects} = Turn.step(data.turn_state, {:llm_error, :turn_timeout})
    interpret(effects, %{data | turn_state: state, task_ref: nil, task_pid: nil})
  end

  # A result or :DOWN from a task that was already timed out (it sent just before
  # being killed) carries a stale ref: drop it instead of crashing the server.
  def handle_event(:info, {ref, _stale_result}, _state, %Data{task_ref: tref})
      when is_reference(ref) and ref != tref do
    :keep_state_and_data
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _state, %Data{task_ref: tref})
      when ref != tref do
    :keep_state_and_data
  end
```

Placement matters: these clauses go AFTER the existing `:running` task-result and `:DOWN` clauses (which match the CURRENT ref) and BEFORE the postpone clause. Leaving `:running` for `:idle`/`:awaiting_approval` cancels the state timeout automatically (`:gen_statem` semantics), so only in-flight blocking effects are ever on the clock.

3f. In `lib/normandy/agents/turn/session.ex`, add `:turn_timeout_ms` to BOTH `Keyword.take` lists in `rehydrate_and_start/1` (after `:idle_timeout_ms` in each), so `Turn.Session.run/2` callers can configure it.

- [ ] **Step 4: Run the tests**

Run: `mix format && mix test test/agents/turn/server_turn_timeout_test.exs`
Expected: PASS (2 tests, 0 failures; test 1 completes in well under a second — the 5s sleep dies with the killed task).

- [ ] **Step 5: Full suite**

Run: `mix test`
Expected: 0 failures (the 600s default never fires for existing tests).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/turn/server.ex
git add lib/normandy/agents/turn/session.ex
git add test/agents/turn/server_turn_timeout_test.exs
git commit -m "feat(turn): :running turn timeout fails wedged turns with :turn_timeout"
```

---

### Task 8: Redis registry — telemetry on eviction of a dead-looking key (mitigation a)

Requires a reachable Redis.

**Files:**
- Modify: `lib/normandy/behaviours/session_registry/redis.ex`
- Modify: `test/behaviours/session_registry/redis_test.exs`

**Interfaces:**
- Produces: `:telemetry.execute([:normandy, :session_registry, :eviction], %{count: 1}, metadata)` fired from the `whereis` `del_if_owner` eviction path (registry `redis.ex` lines ~121–126). Metadata: `session_id`, `pid`, `pid_node`, `node_absent` (true when the pid's node is neither `node()` nor in `Node.list()` — the split-brain-suspect shape), `deleted` (whether `del_if_owner` actually removed the key, vs. a newer claimant re-owning it), `namespace`.

- [ ] **Step 1: Write the failing test**

In `test/behaviours/session_registry/redis_test.exs`, add inside the module, after the `use Normandy.SessionRegistryContract, …` line:

```elixir
  test "whereis eviction of a dead-looking key emits [:normandy, :session_registry, :eviction]" do
    ns = "normandy_reg_evict_#{System.unique_integer([:positive])}"
    owner = Normandy.Behaviours.SessionRegistry.Redis.new(namespace: ns)

    url = Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
    {:ok, conn} = Redix.start_link(url)

    # A pid on an ABSENT node, crafted in External Term Format (NEW_PID_EXT tag
    # 88, node as SMALL_ATOM_UTF8_EXT tag 119): decodes to a pid on
    # :ghost@nohost, which is neither node() nor in Node.list() — exactly the
    # partitioned-node / lapsed-TTL split-brain-suspect shape the mitigation
    # counts. (Verified: :erlang.binary_to_term/1 yields a pid; node/1 returns
    # :ghost@nohost.)
    ghost_blob = <<131, 88, 119, 12, "ghost@nohost", 1::32, 0::32, 1::32>>
    {:ok, "OK"} = Redix.command(conn, ["SET", "#{ns}:reg:{s-evict}", ghost_blob])

    handler_id = "evict-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:normandy, :session_registry, :eviction],
        fn _event, measurements, metadata, _cfg ->
          send(test_pid, {:evicted, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :none = Normandy.Behaviours.SessionRegistry.Redis.whereis(owner, "s-evict")

    assert_receive {:evicted, %{count: 1}, meta}, 1_000
    assert meta.session_id == "s-evict"
    assert meta.pid_node == :ghost@nohost
    assert meta.node_absent == true
    assert meta.deleted == true
    assert meta.namespace == ns

    # The suspect key is actually gone.
    assert {:ok, nil} = Redix.command(conn, ["GET", "#{ns}:reg:{s-evict}"])
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix format && mix test.redis test/behaviours/session_registry/redis_test.exs`
Expected: FAIL — `whereis` returns `:none` (eviction happens) but `assert_receive {:evicted, …}` times out: no telemetry is emitted yet. Contract tests still pass.

- [ ] **Step 3: Implement**

In `lib/normandy/behaviours/session_registry/redis.ex`, in `handle_call({:whereis, sid}, …)`, replace the not-alive branch

```elixir
            if alive?(pid) do
              {:ok, pid}
            else
              _ = del_if_owner(s.conn, reg_key(s.ns, sid), blob)
              :none
            end
```

with:

```elixir
            if alive?(pid) do
              {:ok, pid}
            else
              deleted =
                case del_if_owner(s.conn, reg_key(s.ns, sid), blob) do
                  {:ok, 1} -> true
                  _ -> false
                end

              # Fix 6 mitigation: a dead-looking mapping evicted here is the
              # split-brain-suspect signal — especially when the pid's node is
              # absent from the cluster (partitioned-but-alive window, or a
              # crashed node whose TTL had not yet lapsed). Count it; consumers
              # alert on node_absent: true.
              :telemetry.execute(
                [:normandy, :session_registry, :eviction],
                %{count: 1},
                %{
                  session_id: sid,
                  pid: pid,
                  pid_node: node(pid),
                  node_absent: node(pid) != node() and node(pid) not in Node.list(),
                  deleted: deleted,
                  namespace: s.ns
                }
              )

              :none
            end
```

- [ ] **Step 4: Run the test**

Run: `mix format && mix test.redis test/behaviours/session_registry/redis_test.exs`
Expected: PASS (contract + 1 new test, 0 failures).

- [ ] **Step 5: Full Redis suite and default suite**

Run: `mix test.redis && mix test`
Expected: 0 failures in both.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/behaviours/session_registry/redis.ex
git add test/behaviours/session_registry/redis_test.exs
git commit -m "feat(session-registry): telemetry on redis registry eviction of dead-looking keys"
```

---

### Task 9: Documentation (mitigation c) + final verification

**Files:**
- Modify: `lib/normandy/behaviours/session_registry/horde.ex` (moduledoc — the Horde netsplit-behavior section lives HERE, on the registry module)
- Modify: `lib/normandy/behaviours/session_store/mnesia.ex` (moduledoc — fencing deferral rationale)

- [ ] **Step 1: Horde netsplit section**

Append to the `@moduledoc` of `Normandy.Behaviours.SessionRegistry.Horde`:

```markdown

  ## Netsplit behavior and limits

  Horde's registry is a CRDT with no fencing: during a network partition each
  side converges independently, so BOTH partitions can register (and run) a
  `Turn.Server` for the same `session_id`. On heal, Horde resolves the name
  conflict and terminates one duplicate — but during the split, two live
  servers exist and interleave writes into any shared `SessionStore`.

  Normandy's defense is store-level epoch fencing (critical-fixes Fix 6): each
  server acquires a per-session epoch at start
  (`SessionStore.acquire_epoch/2`, supported by the Postgres and Redis stores)
  and every hot-path write carries it; a stale writer gets `{:error, :fenced}`
  and stops `:normal`. With a fencing store a split can still double-EXECUTE
  side effects (both servers call the LLM and tools until one is fenced or its
  `:turn_timeout_ms` watchdog fires), but it cannot interleave persisted
  writes: only the newest claimant's writes land. With a non-fencing store
  (ETS/InMemory: node-local by construction; Mnesia: fencing deferred, see its
  moduledoc), duplicate servers during a split remain possible — prefer a
  fencing store when running Horde across nodes.
```

- [ ] **Step 2: Mnesia deferral note**

Append to the `@moduledoc` of `Normandy.Behaviours.SessionStore.Mnesia`:

```markdown

  ## Split-brain fencing (deferred)

  This store does NOT implement the optional `acquire_epoch/2` fencing callback
  (critical-fixes Fix 6); its writes are the unfenced 3-arity forms — the
  contract's "epoch 0, writes unchecked" default. Rationale: Mnesia's own
  partition semantics make a per-session epoch counter insufficient — during a
  partition each island commits transactions locally and Mnesia reports
  `running_partitioned_network` on heal, requiring operator-driven
  reconciliation, so the epoch itself would diverge across islands and give
  false safety. Mnesia is also the least production-used backend with the
  hardest transaction/partition semantics to fence correctly. Fencing here is
  deferred until there is a real deployment to design against; use the Postgres
  or Redis store where split-brain fencing matters.
```

- [ ] **Step 3: Verify docs compile and everything is green**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: clean compile, 0 test failures.

- [ ] **Step 4: Service suites + Dialyzer (CI gate)**

Run: `mix test.postgres && mix test.redis && mix dialyzer`
Expected: 0 failures in both suites; Dialyzer passes with no new warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/session_registry/horde.ex
git add lib/normandy/behaviours/session_store/mnesia.ex
git commit -m "docs: horde netsplit limits + mnesia fencing deferral"
```

---

## Completion checklist

- [ ] `mix format` produces no diff; `mix test` → 0 failures (baseline 1432 tests grows by this plan's new tests; the `[error] normandy agent exception` log lines are expected output, not failures).
- [ ] `mix test.postgres` → 0 failures (fence contract active for Postgres).
- [ ] `mix test.redis` → 0 failures (fence contract + eviction telemetry active for Redis).
- [ ] `mix dialyzer` → no new warnings.
- [ ] `save_config_template` has NO 4-arity form anywhere (unfenced by design).
- [ ] ETS/InMemory store code untouched; Mnesia touched only in `@moduledoc`.
- [ ] `Turn.Driver` and `Turn.Inline` untouched (no new core effect was introduced).
