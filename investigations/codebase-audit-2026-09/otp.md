# Audit: `otp` area

Scope: lib/normandy/coordination/**, resilience/**, behaviours/**, mcp/**, a2a/**, batch/**, cluster.ex, mix.exs, config/*.exs.
Branch feat/claudio-0.7-migration @ 78ca1ab. Read-only; no `mix` run. "Verified" = I read the code path; "theory" = needs a run/test to confirm.

### OTP-1. Store `load_turn_state/2` swallows backend failures as "no turn state"
- Severity: HIGH
- Category: 1 (silent fallbacks), 4 (contract)
- Location: lib/normandy/behaviours/session_store/redis.ex:84-89, lib/normandy/behaviours/session_store/mnesia.ex:135-140 (same shape in `load_config_template`: redis.ex:108-113, mnesia.ex:152-157); callers lib/normandy/agents/turn/session.ex:78-81, turn/server.ex:153-158, 160-164
- Evidence:
  ```elixir
  # redis.ex
  case Redix.command(conn, ["HGET", meta_key(ns, session_id), "turn_state"]) do
    {:ok, blob} when is_binary(blob) -> {:ok, decode(blob)}
    _ -> :error
  end
  # mnesia.ex
  case txn(fn -> :mnesia.read({st, session_id}) end) do
    {:ok, [{_, ^session_id, %{turn_state: ts}}]} when not is_nil(ts) -> {:ok, ts}
    _ -> :error
  end
  # server.ex:153
  case mod.load_turn_state(handle, sid) do {:ok, ts} -> ts; _ -> nil end
  ```
- Why it's a problem: the callback type is `{:ok, term} | :error`, so there is no way to say "backend failed". A Redis timeout/MOVED/connection error or a Mnesia `{:aborted, ...}` (for example `{:no_exists, table}` right after a restart, or a partition) is reported as "this session has no turn state". Rehydration then starts with `turn_state = nil`, so a parked or in-flight turn is silently dropped. The next `save_turn_state` overwrites the real durable state with the fresh one. `history/2`, by contrast, does return `{:error, _}` and fails closed in `reconstruct_config!`. Turn state is the load-bearing durability piece and gets the weaker treatment. Postgres raises instead, so the three backends disagree.
- Fix: change the callbacks to `{:ok, term} | :error | {:error, term}`. Map transport/txn errors to `{:error, reason}` in Redis/Mnesia and propagate them in `Session.rehydrate_and_start`, `Server.init` and `ResumeReaper` as start failures, the way `history/2` already is.
- Confidence: verified for the swallow. The downstream data-loss scenario is theory (needs a Redis blip during rehydrate to confirm).

### OTP-2. `ParallelOrchestrator.execute_same_input/3` crashes whenever a worker has no `:transform`
- Severity: HIGH
- Category: 4 (contract), 7 (untested public function)
- Location: lib/normandy/coordination/parallel_orchestrator.ex:219-232 (spec build), 136-144 (use)
- Evidence:
  ```elixir
  transform: Map.get(agent_info, :transform)          # => key present, value nil
  ...
  transform_fn = Map.get(spec, :transform, & &1)       # key exists, so the default is NOT used => nil
  transformed = transform_fn.(agent_result)            # nil.(...)
  ```
- Why it's a problem: the documented example (`execute_same_input(agents, input_data, max_concurrency: 5)` with `%{id:, agent:}` maps) builds specs with `transform: nil`. `Map.get/3` returns `nil` because the key is present, so `nil.(result)` raises `BadFunctionError` inside the `Task.async_stream` task. The task is linked, so the caller dies. This sits outside `execute_agent`'s `rescue`. Every agent that succeeds still crashes the orchestration. `grep -rn execute_same_input lib test` shows no caller and no test, so nothing has ever exercised it.
- Fix: `transform: Map.get(agent_info, :transform, & &1)` (or drop the key when nil). Add a test.
- Confidence: verified by reading (a run would confirm it in seconds).

### OTP-3. `AgentPool` documents error tuples that are never returned; saturation and function errors surface as exits or raises
- Severity: HIGH
- Category: 4 (contract), 8 (docs vs reality)
- Location: lib/normandy/coordination/agent_pool.ex:118-137 (docs), 140-157 (`transaction/3`), 179-184 (`checkout/2`), 233-248 (`handle_call({:checkout, ...})`)
- Evidence:
  ```
  ## Returns  - `{:error, :timeout}` - Checkout timeout
              - `{:error, :pool_exhausted}` - No agents available and max overflow reached
              - `{:error, reason}` - Function raised an error
  ---
  GenServer.call(pool, {:checkout, block}, timeout)       # no catch :exit
  try do result = fun.(agent_pid); {:ok, result} after checkin(...) end   # no rescue
  ```
- Why it's a problem:
  - A blocked checkout that times out is a `GenServer.call` timeout, which is an `exit`. `{:error, :timeout}` is never returned.
  - `:pool_exhausted` appears nowhere in the module. The code returns `{:error, :no_agents}`, and only for `block: false`.
  - `transaction/3` has no `rescue`, so a raising function propagates instead of returning `{:error, reason}`. The `{:ok, result}` wrapper means a function that returns `{:error, _}` comes back as `{:ok, {:error, _}}`, which the docs do not say.
  - A caller written to the docs (`case transaction(...) do {:error, :timeout} -> ... end`) crashes with an exit exactly when the pool is under load. Such a caller is also the one that triggers the known A1 stale-waiter leak.
- Fix: in `checkout/2`, `catch :exit, {:timeout, _}` and return `{:error, :timeout}`, with the server removing that `from` from `waiting` (this also fixes A1's stale waiters). Return `{:error, :pool_exhausted}` for the cap-reached case, or fix the docs. Either rescue in `transaction/3` or fix the doc line.
- Confidence: verified.

### OTP-4. `Batch.Processor` returns `nil` for failed items by default; other results disagree with their own types and docs
- Severity: HIGH
- Category: 1 (silent fallback), 4 (typespec lies)
- Location: lib/normandy/batch/processor.ex:243-257 (`process_results`), 197-222 (`process_batch_chunked`), 122 (progress), 55-62 (`batch_result` type), 262-283 (`results_to_stats`)
- Evidence:
  ```elixir
  {:ok, {:error, _error}} -> nil
  {:exit, _reason} -> nil
  ...
  if chunk_delay > 0 and index < div(total, chunk_size) do Process.sleep(chunk_delay) end
  if on_progress, do: on_progress.(index + 1, total)
  @type batch_result :: %{errors: [{term(), term()}], ...}   # but reduce emits bare `error`, not {input, error}
  ```
- Why it's a problem:
  - **Default ordered mode (`ordered: true`) maps every failed item to `nil`.** A caller doing `{:ok, results} = process_batch(...)` cannot tell a failed item from an agent that returned `nil`. The error callback is the only signal, and it is optional.
  - `process_batch_chunked` uses the same default, so a failure is `nil`. With `ordered: false` it returns only the success list, so the result no longer lines up with the inputs.
  - The `errors` type promises `{input, error}`, but `results_to_stats` stores the bare error (the input is not available there), so unordered errors cannot be matched back to inputs.
  - `on_progress` receives the item's index, not a completion count. With concurrency it reports `3/10, 1/10, 2/10`, contradicting the documented `(completed, total)`.
  - `index < div(total, chunk_size)` sleeps after the last chunk whenever `total` is a multiple of `chunk_size` (100 items / 50: indexes 0 and 1, `div` = 2, so it sleeps after chunk 1 as well).
  - `process_single(agent, input, _timeout)` ignores its timeout argument.
- Fix: return `{:ok, _} | {:error, _}` per item in ordered mode (`[{:ok, r} | {:error, e}]`), use `Enum.count`/an `:atomics` counter for progress, and compare `index < length(chunks) - 1`. Fix the `errors` type or carry the input through.
- Confidence: verified by reading. The off-by-one is arithmetic, not run.

### OTP-5. `HierarchicalCoordinator` round-robin loses worker outputs whenever tasks outnumber workers; specs lie about the return
- Severity: HIGH
- Category: 1 (silent data loss), 4 (typespec)
- Location: lib/normandy/coordination/hierarchical_coordinator.ex:90-91, 142-144 (specs); 252-262 (`create_round_robin_specs`); 107-112 (`{:ok, worker_results} =`)
- Evidence:
  ```elixir
  workers |> Stream.cycle() |> Enum.zip(plan) |> Enum.map(fn {worker, task} -> %{id: worker.id, ...} end)
  # ParallelOrchestrator keys its result map by spec.id: Map.put(succ, agent_id, result)
  @spec execute(t(), term(), keyword()) :: {:error, term()}   # also returns {:ok, result}
  ```
- Why it's a problem: with 2 workers and a 5-item plan, `Stream.cycle` yields specs with ids `w1,w2,w1,w2,w1`. All of them run, but `ParallelOrchestrator` stores results in a map keyed by agent id, so only the last result per worker survives and the manager aggregates 2 of 5. Nothing is reported. Failures are also discarded (known, see list below). Separately, both public `@spec`s say the function can only return `{:error, term()}`, but they return `{:ok, term}`. Dialyzer's `:underspecs` is on and apparently does not catch it.
- Fix: give specs unique ids (`"#{worker.id}##{idx}"`) and map back, or reject plans longer than the worker list. Correct the specs to `{:ok, term()} | {:error, term()}`.
- Confidence: verified (result-map keying read in `execute_with_specs`).

### OTP-6. Sequential/Parallel orchestrators mask agent failures as data
- Severity: MEDIUM
- Category: 1
- Location: lib/normandy/coordination/parallel_orchestrator.ex:101-120 (`execute_simple_api`); lib/normandy/coordination/sequential_orchestrator.ex:148-151 (`on_error: :continue`)
- Evidence:
  ```elixir
  result_list = agent_specs |> Enum.map(fn %{id: id} -> Map.get(results, id) end) |> Enum.filter(&(&1 != nil))
  {:ok, result_list}
  ...
  :continue -> {:cont, {:ok, {:error, reason}, ctx, results ++ [{:error, reason}]}}   # next input = {:error, reason}
  ```
- Why it's a problem:
  - The simple parallel API drops any agent that errored, so `{:ok, list}` has fewer elements than agents and positions shift. A caller that zips the list with its agents gets mismatched answers. It also drops a legitimate `nil` result.
  - In sequential `:continue` mode the failure tuple becomes the next agent's `input`. `prepare_input/1` passes a non-map, non-binary term straight through, so the next LLM call receives `{:error, reason}` as its prompt and its answer is recorded as a normal result.
- Fix: parallel simple API returns `{:error, errors}` or keeps `{id, result}` pairs. Sequential `:continue` should carry the previous successful input forward (or document a `:skip` strategy), not forward the error tuple.
- Confidence: verified.

### OTP-7. `PolicyEngine.Ruleset` fails open on malformed rules
- Severity: MEDIUM
- Category: 1, 2 (silent defaulting on a security control)
- Location: lib/normandy/behaviours/policy_engine.ex:56-66
- Evidence:
  ```elixir
  default_action = Keyword.get(opts, :default_action, :allow)
  case Enum.find(rules, fn rule -> matches?(rule[:match], name) end) do
    nil -> decide(default_action, empty_meta())
    rule -> decide(rule[:action] || :allow, rule_meta(rule))
  ```
- Why it's a problem: a rule such as `%{match: "delete_*", acton: :deny}` (typo) or `%{match: "delete_*"}` matches and then allows, with no error. `:default_action` defaults to `:allow`, so an empty or mistyped `rules` option allows everything. `call_name/1` maps a non-binary or missing name to `""`, which only a `"*"` rule can match. Policy is the one place where "unknown means deny" should hold. Typo'd action atoms do crash (`decide/2` has no catch-all), which is good, but the missing-key case does not.
- Fix: `Keyword.fetch!(opts, :rules)`, `Map.fetch!(rule, :action)` and a validation pass at config time. Consider default `:deny` (or require `:default_action`).
- Confidence: verified.

### OTP-8. Budget tracker's `{module, opts}` opts are silently dropped
- Severity: MEDIUM
- Category: 2 (option handling), 4
- Location: lib/normandy/behaviours/config.ex:68-84 (`to_pipeline/1`); callbacks lib/normandy/behaviours/budget_tracker.ex:14-15
- Evidence:
  ```elixir
  {budget_mod, _budget_opts} = bundle.budget
  budget_check_fn: fn config, call -> budget_mod.check(scope(config), call) end,
  ```
- Why it's a problem: every other behaviour ref passes its `opts` (policy gets `ctx.opts`). The budget ref accepts opts but the callbacks have no opts parameter, so a real tracker cannot receive limits, a store handle or a name via the documented config slot. The only way to configure it is global state (a named process, app env). `{BudgetTracker.MyTracker, limit: 100}` is accepted and ignored. The same applies to `scope/1`: `Map.get(config, :name)` is `nil` for unnamed agents, so all unnamed agents share one scope.
- Fix: add `opts` to `check/3` and `record/3` (the behaviour is new, so it can change), or pass `opts` inside `scope`. Validate refs in `Config` when built.
- Confidence: verified.

### OTP-9. `mix.exs` starts `:mnesia` for every consumer
- Severity: MEDIUM
- Category: Global state / library config hygiene
- Location: mix.exs:`application/0`
- Evidence: `extra_applications: [:logger, :mnesia]`
- Why it's a problem: entries in `extra_applications` are started with the app. Every consumer, including Tier-0 users who never touch Mnesia, boots the Mnesia application at startup (and is affected by `-mnesia dir`/schema configuration). `SessionStore.Mnesia.ensure_started!/0` already starts it lazily, which shows it was meant to be on demand. The same module is also the only user of Mnesia. Making `:mnesia` mandatory also breaks releases built without it.
- Fix: `extra_applications: [:logger, mnesia: :optional]` (Elixir >= 1.15, which this project requires, supports `:optional`), and rely on `ensure_started!`.
- Confidence: verified from mix.exs. The runtime effect is documented Mix behaviour (I did not run a release).

### OTP-10. `SessionRegistry.Redis` calls plain `binary_to_term/1` on data read from shared Redis
- Severity: MEDIUM
- Category: 3 (security), 1
- Location: lib/normandy/behaviours/session_registry/redis.ex:117-128 (`:whereis`)
- Evidence:
  ```elixir
  pid = :erlang.binary_to_term(blob)
  if alive?(pid) do ...   # alive?/1 does node(pid) / Process.alive?(pid)
  ```
- Why it's a problem: the comment treats the value as trusted, but it is read from a Redis keyspace that other clients and other deployments sharing the instance can write. Anyone with write access can inject a term that creates unbounded atoms (atom-table exhaustion kills the VM) or a non-pid term. A non-pid makes `node/1` raise `ArgumentError` inside the owner GenServer, which crashes the owner. That drops every locally monitored registration, and the supervisor restarts with `sids: %{}`. A single bad key therefore wipes the node's registrations. The `:safe` concern in the comment is real for node atoms, but the fix is to store `node@host` plus a serialized pid/ref and decode defensively, not unrestricted decode.
- Fix: decode with `[:safe]` and fall back to an explicit "pid from unknown node" path (`Node.connect`-free), or store `{node_string, pid_string}` and use `:erlang.list_to_pid/1`. Wrap in `try/rescue` returning `:none`, and `is_pid` guard before `alive?`.
- Confidence: verified for the unsafe decode. The crash path is a short read of `alive?/1`.

### OTP-11. Mnesia store: no `wait_for_tables`, and a broken chain silently truncates history
- Severity: MEDIUM
- Category: 6 (OTP), 1
- Location: lib/normandy/behaviours/session_store/mnesia.ex:49-62 (`create_tables`), 180-199 (`chain/3`)
- Evidence:
  ```elixir
  [] -> acc            # chain/3: missing parent entry => returns a truncated history, no error
  ```
  `grep -rn wait_for_tables lib` returns nothing.
- Why it's a problem:
  - After a restart with `disc_copies`, `create_table` returns `already_exists` (treated as success) while tables load asynchronously. Transactions in that window abort with `{:no_exists, table}` or `{:aborted, ...}`. Combined with OTP-1 these show up as "no turn state", and `append_entry` returns an error.
  - `chain/3` returns whatever it has when a parent id is missing (a table loaded partially, or a replica not yet synced), so `history/2` returns `{:ok, truncated}`. The LLM then continues from a conversation with missing context and nothing flags it. `fork` and `on_chain?` have the same shape, but they return false and abort instead.
- Fix: call `:mnesia.wait_for_tables([entries, sessions], timeout)` at the end of `create_tables/1` and raise on timeout. Make `chain/3` abort with `{:broken_chain, id}` on a missing non-nil parent.
- Confidence: theory for the restart window (needs a disc_copies restart test), verified for the truncation in `chain/3`.

### OTP-12. Redis store: `wait:` documented but not implemented; replica-ack not applied to entries
- Severity: MEDIUM
- Category: 8 (docs vs reality), 5 (global state), 2
- Location: lib/normandy/behaviours/session_store/redis.ex:16-18 (moduledoc), 130-146 (`wait/3`), 36-43 (`append_entry`)
- Evidence:
  ```elixir
  # moduledoc: "pass `wait: {numreplicas, timeout_ms}` so boundary writes block on replica acknowledgement"
  defp wait({conn, _ns}, num \\ nil, timeout \\ nil) do
    {n, t} = Application.get_env(:normandy, :redis_wait, {0, 0})
  ```
- Why it's a problem: there is no `wait:` option anywhere (`new/1` ignores it; the handle is `{conn, ns}`). `docs/guides/distributed_sessions.md:207` says to use the global `:redis_wait` app env instead, so the two docs contradict each other. The default `{0, 0}` is a silent no-op. `wait/1` runs only after `save_turn_state` and `save_config_template`. `append_entry` (the assistant `tool_use` message written before dispatch) has no replica wait, so the "fail-closed boundary" guarantee does not cover the conversation. Two stores in one VM cannot use different settings (global env). The `num`/`timeout` parameters are dead.
- Fix: carry `wait` in the handle (`{conn, ns, wait}`) or read opts at `new/1`, apply it after `XADD` as well, and fix the moduledoc.
- Confidence: verified.

### OTP-13. A2A server drops context and non-text input, and leaks internals to the caller
- Severity: MEDIUM
- Category: 1, 3 (information exposure)
- Location: lib/normandy/a2a/server.ex:80-100 (`handle_message` input), 128-135 (rescue), 148-156 (`extract_response_text`), 138-146 (`add_tool_skills`)
- Evidence:
  ```elixir
  message.parts |> Enum.map_join("\n", fn part -> Map.get(part, :text, "") end)
  ...
  {:error, Exception.message(error)}
  defp extract_response_text(response), do: inspect(response)
  ```
- Why it's a problem:
  - A message with only file/data parts becomes `""` and is run as an empty prompt (the LLM answers anyway).
  - `context_id`/`task_id` are ignored: `BaseAgent.run(config, ...)` runs on the same initial `config` every time, so a multi-turn A2A conversation silently has no memory.
  - `Exception.message/1` is returned verbatim to the remote A2A client and may carry internal details (LLM client errors, paths). The fallback `inspect(response)` can send an entire struct, possibly with metadata, to the remote.
  - `add_tool_skills` advertises every registered tool name and description in the public agent card, which can include internal or privileged tools.
  - `rescue` only catches raises, so an exit from the LLM client (`GenServer.call` timeout) crashes the caller's process instead of returning `{:error, _}`.
- Fix: reject messages with no text, accept an opt for a session/memory strategy, return a generic error (log the detail), `catch :exit`, and add an `:expose_tools` (allowlist) option to the card builder.
- Confidence: verified.

### OTP-14. MCP/A2A tool registration silently overwrites on name collision
- Severity: MEDIUM
- Category: 1
- Location: lib/normandy/mcp/registry.ex:30-42, lib/normandy/a2a/agent_tool.ex:62-70 (`sanitize_name`), lib/normandy/a2a/registry.ex:52-64; `Normandy.Tools.Registry.register/2` (registry.ex:61-64, `Map.put`)
- Evidence:
  ```elixir
  # MCP: no :prefix => tool_name is the bare MCP name
  Enum.reduce(wrappers, registry, fn wrapper, reg -> Registry.register(reg, wrapper) end)
  # A2A: sanitize collapses punctuation
  String.replace(~r/[^a-z0-9_]/, "_") |> String.replace(~r/_+/, "_")
  ```
- Why it's a problem: two MCP servers registered without distinct prefixes that both expose `search` end up with only the last one, with no error or log; tool calls go to the wrong server. For A2A, skill ids `"a-b"` and `"a_b"` (or `"A B"`) sanitize to the same name, so one skill disappears. `:prefix` is optional and unknown opts are ignored, so a typo like `prefix:` mistakes are not flagged. Names are not length- or charset-checked against what the Anthropic API accepts (`^[a-zA-Z0-9_-]{1,64}$`): MCP names containing `.` or exceeding 64 chars produce an API 400 at request time, far from the registration (theory, not run).
- Fix: have the discover functions return `{:error, {:duplicate_tool, name}}` (or raise) when the name is already registered, and validate names at wrap time. Make `:prefix` required when more than one server is used.
- Confidence: verified for the overwrite, theory for the API-name constraint.

### OTP-15. `Retry` / `CircuitBreaker` option and contract looseness
- Severity: LOW
- Category: 2, 4
- Location: lib/normandy/resilience/retry.ex:110-128 (opts), 144-170 (return shapes), 191-200, 232-235, 300-304 (`preset/1`); circuit_breaker.ex:345-350
- Evidence:
  ```elixir
  @spec with_retry(...) :: {:ok, term()} | {:error, {term(), pos_integer(), [term()]}}
  ... {:error, error}                      # non-retryable branch: bare error, not the triple
  def preset(_), do: preset(:standard)
  |> Macro.underscore() |> String.to_atom()
  other -> {:ok, other}                     # CircuitBreaker: non-tuple returns recorded as success
  ```
- Why it's a problem:
  - The `with_retry` spec promises the `{error, attempts, errors}` triple, but a non-retryable error returns the bare `{:error, error}`, so callers pattern-matching on the spec crash.
  - `Keyword.get` with unknown keys: `max_attempts: 0` falls through to `:unknown_error`; a typo such as `max_attemps:` is ignored; `preset(:persistant)` silently becomes `:standard`.
  - `retry.ex:234` creates atoms from exception module names (bounded by loaded modules, so low risk).
  - `Retry` treats a non-tuple return as `{:error, {:unexpected_return, _}}` while `CircuitBreaker.call/2` treats the same value as success and rewraps it as `{:ok, other}`; composing the two changes the outcome.
  - `execute_with_timeout/1` has no timeout despite its name.
- Fix: validate opts with `Keyword.validate!/2`, make `preset/1` raise on unknown names, return one shape from `with_retry`, align the non-tuple handling between the two modules.
- Confidence: verified.

### OTP-16. `Turn.Supervisor` runs on DynamicSupervisor default restart intensity
- Severity: MEDIUM
- Category: 6
- Location: lib/normandy/agents/turn/supervisor.ex:13 (`DynamicSupervisor.init(strategy: :one_for_one)`), :20-25 (`restart: :transient`)
- Evidence: no `max_restarts`/`max_seconds`, so the defaults (3 restarts in 5 s) apply across all sessions under one supervisor.
- Why it's a problem: restart intensity is shared by every live session. Any 4 abnormal `Turn.Server` exits within 5 s, from unrelated sessions, terminate `Turn.Supervisor` and every session with it. AGENTS-1 removes the known crash sources (rejected input, raising handlers/subscribers), but a library that hosts many independent sessions should not let unrelated failures cascade. Not addressed by the AGENTS-1 fix.
- Fix: decide the policy explicitly: expose `:max_restarts`/`:max_seconds` on `Turn.Supervisor.start_link/1` with documented defaults sized for many sessions, or use `restart: :temporary` and rely on store-backed resume (ResumeReaper) instead of supervisor restarts. Public decision.
- Confidence: verified (code); not load-tested

## Known (from prior audit, `investigations/performance-race-audit.md`)
- A1 AgentPool leaks agents (stale waiters, no client monitor, double replacement): still present. lib/normandy/coordination/agent_pool.ex:233-248 (checkout parks `from` with no monitor), 253-262 (monitors the agent, not the client), agent_supervisor.ex:79-90 (default `:transient`).
- A2 CircuitBreaker wedges in half-open: still present. circuit_breaker.ex:318-339 (`rescue` only, no `catch`), 205-212 (`:try_half_open_call` never checks `state.state`).
- A5 ParallelOrchestrator no `on_timeout: :kill_task`: still present. parallel_orchestrator.ex:132-152; the `{:exit, {agent_id, reason}}` clause (~172) is still the wrong shape.
- A6 Batch.Processor no `on_timeout`: still present. batch/processor.ex:116-136, and `{:ok, _} =` at 207.
- A7 Inline AgentProcess blocks its GenServer during the whole turn: still present. agent_process.ex:370-402.
- MEDIUM (lines now): inline async Task rescue-only and no memory (agent_process.ex:486-516, 600-617); atom leak (agent_process.ex:304); Reactive.all resets accumulator on timeout (reactive.ex:183) and pid-branch no exit handling (reactive.ex:325-327); `AgentSupervisor.list_agents` check-then-act (agent_supervisor.ex:136-144); StatefulContext `get_table` call per read and `:public` ETS (stateful_context.ex:226, 237-242); Hierarchical worker errors never inspected (hierarchical_coordinator.ex:107-112); Redis fork id collision (session_store/redis.ex:63); Redis whereis transport error -> `:none` (session_registry/redis.ex:128-129); Redis pipeline `{:ok, _}` ignoring in-band errors (session_store/redis.ex:99-103); Sequential `MatchError` on failure (sequential_orchestrator.ex:93); `Retry` jitter `:rand.uniform(0)` for `base_delay < 4` (retry.ex:260-263); pool lifo/fifo inverted (agent_pool.ex:377-391); Redis registry TTL refresh never re-claims a lapsed key (redis.ex:165-171).

## Area summary
- The highest-severity problems in this area are contracts and silent masking, not process-level races. Docs and specs promise error tuples (`AgentPool`, `Hierarchical`, `Batch`, `Retry`) that the code does not return, and failure is turned into `nil`, `:error` or a dropped element in several places. Several of these have no test (`execute_same_input` has no caller at all).
- The durable-store layer is inconsistent about failure: Postgres raises, Redis and Mnesia convert backend errors into "not found". Combined with the lack of table-readiness handling in Mnesia and global `:redis_wait`, the fail-closed story in the docs does not hold for turn state.
- Library hygiene is mostly good (optional deps conditionally compiled, `Inspect` derives that hide tokens in `ServerConfig`/`AgentTool`, `binary_to_term(..., [:safe])` on stores, config files not packaged). Exceptions: `:mnesia` in `extra_applications`, the `path: "../Claudio"` dep (acknowledged in CLAUDE.md, blocks `hex.publish`), and `priv/test_repo` migrations shipped via `files: ~w(lib priv ...)`. Several Phase-N moduledocs are stale: ETS, InMemory, `Behaviours.Config` and `CredentialProvider` say "not yet consumed by the turn loop", and `SessionRegistry` says distributed impls are "deferred" although Horde and Redis exist.
