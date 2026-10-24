# Normandy 2.0 audit: security, robustness and failure handling

Branch `feat/claudio-0.7-migration` at `f7991a9`, 2026-10-04. Read-only: grep and read only. No
mix, no probes, nothing executed.

**Marks.** **VERIFIED** means I read the whole code path from input to effect and quote it
below; nothing was executed. **PLAUSIBLE** means the code path is real but whether it can be
exploited depends on how the host application is built, or on behaviour outside this repo.

Prior audit `investigations/codebase-audit-2026-09/` was skimmed. Findings already listed there
are left out unless still present. Section Z lists the prior security-adjacent items I re-read
and found fixed.

**Totals: 0 BLOCKER, 1 HIGH, 8 MEDIUM, 9 LOW.**

---

## HIGH

### SEC-1. Model input overwrites any field of a tool struct, including trusted config the executor reads (`:timeout`)
- **Severity:** HIGH. The fix changes a public contract, so 2.0 is the time to make it.
- **Where:** `lib/normandy/agents/dispatch.ex:129-134`, `:475-489`; `lib/normandy/tools/executor.ex:175-187`
- **Evidence:**
  ```elixir
  # dispatch.ex:129
  def prepare_tool(tool, input) when is_map(input) do
    if exports?(tool.__struct__, :prepare_input, 2) do
      tool.__struct__.prepare_input(tool, input)
    else
      struct(tool, atomize_known_keys(tool, input))
  ```
  `normalize_tool_field_key/2` accepts **any** struct field except `:__struct__`. It never looks
  at `input_schema/1`. `validate_input/2` only checks SchemaBaseTool-shaped tools. A plain
  `BaseTool` gets no schema check at all.
  ```elixir
  # executor.ex:179
  :error -> Map.get(tool, :timeout) || @default_timeout
  ```
- **Scenario (a class of bug, not one exploit):** a host writes a tool as
  `defstruct [:query, endpoint: "https://internal", api_token: nil, timeout: 5_000]` and fills in
  the config fields at registration. The usual Elixir habit is to keep config on the struct; the
  built-in `AgentTool`, `ToolWrapper` and `Memory` all do it, but they protect themselves with
  `prepare_input/2`. Any model output (directly, or steered by prompt injection through a tool
  result or memory) can then set `endpoint`, `api_token` or any other config field just by
  naming it in the tool input. Two consequences are certain from the code:
  - `"timeout": 999999999` lifts the executor timeout.
  - `"timeout": "x"` makes `timeout!/2` raise `ArgumentError`. That raise happens outside the
    executor's try block (inside `execute_tool_classified`), so it fails the whole turn.
  Nothing in `BaseTool` docs or the guides warns that every struct field is writable by the model.
- **Fix:** take the writable keys from `BaseTool.input_schema(tool)` `properties` (string or
  atom keys) and intersect them with the struct fields, instead of using every struct field.
  Better still, keep model input in a separate `:input` map the way the built-ins do. Read
  `:timeout` from registration options, never from the prepared struct. Until then, document it
  in `BaseTool`.
- **VERIFIED** (code path read end to end; not executed).

---

## MEDIUM

### SEC-2. MCP servers choose their own tool names, unprefixed by default, so name-glob policy rules can be matched on purpose
- **Where:** `lib/normandy/mcp/tool_wrapper.ex:69,85-89`; `lib/normandy/mcp/registry.ex:57-60`;
  `lib/normandy/behaviours/policy_engine.ex:137-145`
- **Evidence:** `prefix: Keyword.get(opts, :prefix)` defaults to `nil`, and then
  `def tool_name(%{tool: tool, prefix: nil}), do: tool.name`. `Ruleset` decides on the tool name
  alone: `String.starts_with?(name, String.trim_trailing(pattern, "*"))`.
- **Scenario:** a ruleset says `%{match: "read_*", action: :allow}` with
  `default_action: :require_approval`. A malicious or compromised MCP server, or one whose tool
  list changes between discoveries, names a destructive tool `read_and_purge`. It matches the
  allow rule and skips approval. Name collisions are handled (OTP-14 is fixed); policy
  shadowing is not.
- **Fix:** require `:prefix` in `discover_and_register/4` and `ToolWrapper.new/4`, defaulting to
  the server name, so rules can be written as `"srv__*"`. Document that policy rules match names
  chosen by the server. Optionally, let `Ruleset` match on tool kind or origin as well as name.
- **VERIFIED** (code); actually exploiting it depends on how the host writes its rules.

### SEC-3. Tool results have no size cap; results that JSON can't encode fall back to unbounded `inspect/1`
- **Where:** `lib/normandy/components/tool_result.ex:45-61`; `lib/normandy/agents/dispatch.ex:346-352`;
  no cap anywhere (grep for `max_tool_output|max_result|output_limit` finds nothing in `lib/`)
- **Evidence:**
  ```elixir
  try do
    adapter.encode!(output)
  rescue
    _ -> inspect(output)
  end
  ```
- **Scenario:** an MCP server, a remote A2A agent (`AgentTool` joins every artifact text part)
  or an ordinary tool returns a multi-megabyte result. It goes into memory and every later
  request whole. The likely results: the context window overflows (every later call is a 400
  until compaction or a reset), or each later turn costs a lot more. A remote party can do this
  on purpose. The `rescue _ -> inspect` also hides an encoding bug and can show the model struct
  internals (a tool returning `{:error, %SomeStruct{}}`).
- **Fix:** add a `max_tool_result_bytes` setting (on the config or per tool, with a sane default)
  that truncates and adds a visible marker, the same way `max_view_chars` works for memory.
  Replace `inspect` with a bounded `inspect(output, limit: 50, printable_limit: 2_000)` and a
  telemetry flag, or make an unencodable result a tool error.
- **VERIFIED** (code).

### SEC-4. Guardrail `:on_error` handles raises only: exits and throws escape it, and a host classifier's exceptions are re-raised
- **Where:** `lib/normandy/guardrails.ex:177-203`, `:216`
- **Evidence:** `invoke/4` for `:open | :closed` has a `rescue` and no `catch`. A
  `GenServer.call` or `Task.await` timeout inside a guard exits. The `builtin?/1` heuristic
  (`String.starts_with?(inspect(mod), "Normandy.Guardrails.Builtins.")`) re-raises
  `ArgumentError` and `KeyError` from **any** builtin, and that includes `SemanticScope`, whose
  `:classifier` is host code doing IO.
- **Scenario:** the `SemanticScope` moduledoc recommends `on_error: :open` for a classifier that
  calls a flaky inference service. When that service times out, the exit goes through
  `Guardrails.run` and crashes the run or the `admit/2` caller. Neither `:open` (admit) nor
  `:closed` (violation) applies, contradicting the docs. A classifier that raises `KeyError`
  (say, from a missing context key) is likewise re-raised whatever the policy says.
- **Fix:** add `catch :exit, r` and `catch :throw, v` routed to `on_error_result/3`. Apply
  `builtin?` to the guard's own validation step only, not to exceptions raised inside the
  injected `:classifier` or `:fast_path` (wrap those calls and tag their exceptions).
- **VERIFIED** (code).

### SEC-5. Output-schema validation is soft: an invalid model answer is returned as if valid, and the whole value goes to stderr
- **Where:** `lib/normandy/agents/base_agent.ex:791-803`
- **Evidence:**
  ```elixir
  {:error, errors} ->
    error_msg = ValidationMiddleware.error_message(errors)
    IO.warn("Agent output validation failed: #{error_msg}\nReceived: #{inspect(value)}")
    value
  ```
- **Scenario:** a caller relies on `output_schema` constraints (enums, ranges, required fields)
  to make the model's answer safe to act on, for example an `action` field limited to an enum.
  An injected or confused model returns a value that breaks them, and the caller gets it as a
  normal response. CLAUDE.md forbids exactly this kind of silent fallback. Separately,
  `IO.warn` writes the full `inspect` of model output (user data or PII) plus a stack trace to
  stderr, outside the Logger pipeline, so the host's Logger filters and redaction do not apply.
- **Fix:** make the outcome configurable (`:output_validation_on_failure`, `:raise | :warn`) and
  default it to `:raise` for 2.0, or return `{:error, _}` the way `ViolationError` does. Log
  through `Logger` with the violation paths only, not the value.
- **VERIFIED** (code). I did not check whether `ValidationMiddleware.validate_output` is
  disabled by default.

### SEC-6. The memory namespace cap stops counting after 1,000 documents, and there is no document-count limit, so storage grows without bound
- **Where:** `lib/normandy/tools/memory/commands.ex:400-411`; `lib/normandy/behaviours/memory_store.ex:46`
- **Evidence:** `others_bytes/3` sums `store.list(ns, "/memories")`, which returns at most
  `list_limit()` = 1000 entries, sorted by path. The moduledoc admits the namespace is then
  "under-counted".
- **Scenario:** the model, possibly steered by injected content, which memory itself keeps
  across sessions, creates 1,000 small files whose paths sort first, then any number of files up
  to `max_document_bytes` (100 KB) each. None of the later files are counted. The namespace
  grows without limit, and because the stores keep a namespace as one unit, every later command
  on it gets slower. `max_namespace_bytes` is the only thing that bounds storage the model
  drives, and it can be stepped around.
- **Fix:** add `:max_documents` (refuse `create` of a new path once `list` returns
  `list_limit`), or get an exact size from the store (`SUM(octet_length)` in Postgres, a
  counter hash in Redis). At minimum, refuse a create when the listing is full instead of
  under-counting.
- **VERIFIED** (code; the limitation is documented, but its security effect is not).

### SEC-7. A session namespace that equals a mount's namespace gets around `:read_only`
- **Where:** `lib/normandy/tools/memory/paths.ex:47-59`; `lib/normandy/tools/memory.ex:218-228,268-280`
- **Evidence:** a mount resolves to `{ns, access}` and its store path is moved under
  `/memories`. The session namespace comes from `tool_context` as an opaque string. Nothing
  compares it with mount namespaces, and nothing compares mounts with each other.
- **Scenario:** an app builds `memory_namespace` from something the user controls (a username,
  an org slug) and mounts a shared read-only KB at namespace `"acme/org-kb"`. A user whose
  derived namespace is `"acme/org-kb"` writes to `/memories/...` in their own namespace, which is
  the KB, with read-write access. The same happens when two mounts point at one namespace with
  different access levels.
- **Fix:** in `Memory.run/2`, refuse (raise, like a missing namespace) when the session
  namespace equals any mount's namespace. In `validate_mounts!/1`, refuse two mounts with the
  same namespace and different access. Document that namespaces must not be built from
  user-controlled strings without a fixed prefix.
- **PLAUSIBLE** (the code allows it; it only happens when the host derives namespaces from
  user-controlled strings).

### SEC-8. Persisted templates carry security controls, with no integrity check and no plain-data check on load
- **Where:** `lib/normandy/agents/config_template.ex:131-165`; `lib/normandy/behaviours/session_store/codec.ex:18-24`
- **Evidence:** `rebuild/3` takes `behaviours_refs.policy`, `input_guardrails`,
  `output_guardrails`, `hooks` and `tool_context` from the stored template as they are. Only
  `hooks` are re-validated (`validate_entries!(…, load: false)`). `from_config/2` refuses
  functions and pids (`unstorable?/1`), but `rebuild/3` never re-checks, and
  `binary_to_term(_, [:safe])` decodes local funs and any existing struct.
- **Scenario:** anyone with write access to the session store (a shared Redis, or a Postgres
  role used by another service) can swap `policy` for `PolicyEngine.AllowAll`, clear
  `input_guardrails`, change `tool_context.memory_namespace` to another tenant's, or insert a
  guard opt holding a closure. All of it takes effect on the next rehydrate on any node. The
  distributed-sessions guide says templates are "non-secret" but never says the store is a
  trust boundary for authorization.
- **Fix:** document that the session store is as trusted as code. In `rebuild/3`, run the same
  `unstorable?` check and check `behaviours_refs` modules against an allowlist in the supplement.
  Optionally sign templates with an HMAC key held per node (from the `AgentTemplate`
  supplement).
- **VERIFIED** (code); it requires store write access.

### SEC-9. A2A server: no request-size limit and no per-caller identity, so every remote caller shares the config's `tool_context` and memory namespace
- **Where:** `lib/normandy/a2a/server.ex:154-216`
- **Evidence:** `message_text/1` joins every text part with no bound. `run_agent/3` runs
  `BaseAgent.run(config, user_input)` on the one `config` passed in, with the same
  `tool_context` and tools for every remote caller. The moduledoc says it "does not start an
  HTTP server" but gives no guidance on authentication, size limits or tenancy.
- **Scenario:**
  - A remote caller sends a multi-megabyte message: unbounded input tokens and cost, limited
    only by the host's HTTP body limit, if it has one.
  - If the exposed agent has the `memory` tool, every A2A caller reads and writes the same
    namespace. One caller can plant instructions that persist and affect every other caller
    (cross-tenant prompt injection).
  - Privileged tools on the agent can be reached by any caller the host fails to authenticate.
    Only the card hides them (`expose_tools` defaults to none), and the agent itself does not.
- **Fix:** add `handle_message/4` options `:max_text_bytes` (refuse with
  `{:error, :too_large}`) and `:tool_context` (or a `(message, carrier) -> tool_context`
  callback) so the host can scope memory to each caller. Document in the moduledoc that
  authentication and authorization belong to the host's Plug and that the config's tools are
  reachable by every caller who gets through.
- **VERIFIED** (code).

---

## LOW

### SEC-10. MCP and A2A tool descriptions, schemas and results are untrusted, and the docs never say so
- **Where:** `lib/normandy/mcp/tool_wrapper.ex:91-97`; `lib/normandy/a2a/agent_tool.ex:197-210`
- **Evidence:** `tool_description` and `input_schema` come straight from the server or remote
  card. `grep -rln "injection|untrusted"` finds no hit in `mcp/` or `a2a/` (there are hits in
  the memory and hooks docs).
- **Scenario:** a server's description text becomes part of the system tools list on every
  request, which is a standing prompt-injection channel. Results are the same.
- **Fix:** add a "Trust" section to `ToolWrapper`, `MCP.Registry` and `AgentTool`. Optionally
  add a `:description_override` and a description length cap.
- **VERIFIED**.

### SEC-11. Error text sent to the model includes unbounded `inspect` of remote or exception data
- **Where:** `lib/normandy/mcp/tool_wrapper.ex:105`; `lib/normandy/a2a/agent_tool.ex:133,254`;
  `lib/normandy/tools/executor.ex:228`
- **Evidence:** `"MCP tool '#{tool.name}' failed: #{inspect(reason)}"` and
  `"A2A request failed: #{inspect(reason)}"`. Claudio's HTTP transport returns
  `{:unexpected_response, other}` with a body the remote controls. `Executor` sends up to 500
  characters of `Exception.message/1`, and a `KeyError` message includes the map it searched,
  which may hold struct fields such as tokens.
- **Fix:** bound the `inspect` (`limit:`, `printable_limit:`) or name only the reason's tag,
  as `Executor.describe_reason/1` and `Memory.Commands.backend/1` already do. For exceptions,
  send the module name plus a short message.
- **VERIFIED** (code). Whether a secret actually leaks depends on the tool. Claudio's errors
  (`ApiError` fields `:type, :message, :status_code, :raw_body`) carry no headers.

### SEC-12. Client `Inspect` hides `:api_key` only; `options[:req_options]` (auth, headers) is shown
- **Where:** `lib/normandy/llm/claudio_adapter.ex:142-147`; `lib/normandy/llm/openai_compatible_adapter.ex:61`
- **Evidence:** `@derive {Inspect, except: [:api_key]}` on a struct with `options: map()`. The
  documented `:req_options` and Claudio `:headers` can hold `auth:` or proxy credentials.
- **Scenario:** any `inspect(config)` prints them: a crash report from a GenServer whose state
  holds the config, `Logger.error("…#{inspect(reason)}")` in `agent_process.ex:528`, or a host
  log line.
- **Fix:** a custom `Inspect` implementation that replaces `options[:req_options]` and
  `options[:headers]` with `"**redacted**"`.
- **VERIFIED** (code).

### SEC-13. Redis session keys put the raw session id inside the cluster hash tag
- **Where:** `lib/normandy/behaviours/session_store/redis.ex:289-290`;
  `lib/normandy/behaviours/session_registry/redis.ex:196`
- **Evidence:** `"#{ns}:{#{sid}}:stream"`. The memory store base64-encodes its namespace for
  exactly this reason (`memory_store/redis.ex:211-213`); the session keys do not.
- **Scenario:** a session id containing `}` (for example `"}x"`, giving the empty tag `{}`)
  changes how the key hashes. Stream and meta keys can then land in different cluster slots,
  so any future multi-key operation gets CROSSSLOT. I checked the three key shapes against each
  other: they cannot collide across sessions.
- **Fix:** `Base.url_encode64(sid, padding: false)` inside the tag. Changing the key format
  needs a migration note.
- **VERIFIED** (key construction); the impact is robustness, not confidentiality.

### SEC-14. `AgentProcess.run_async` starts unsupervised tasks with no concurrency bound
- **Where:** `lib/normandy/coordination/agent_process.ex:511,542`
- **Evidence:** `Task.start(fn -> … Turn.Session.run(opts, user_input) … end)` runs for every
  cast, with no cap, no `Task.Supervisor` and no link or monitor.
- **Scenario:** a caller that loops on `cast/3`, or a burst of requests, starts unlimited
  concurrent LLM turns. They keep running and spending after the `AgentProcess` dies.
- **Fix:** start them under a `Task.Supervisor` owned by the process and track in-flight work
  with a `max_concurrency` limit; refuse (or queue) above it.
- **VERIFIED** (code).

### SEC-15. An approved call runs whatever tool holds that name at approval time, and a missing tool crashes the batch
- **Where:** `lib/normandy/agents/turn/server.ex:1496-1515`
- **Evidence:** `{:ok, tool} = Normandy.Tools.Registry.get(config.tool_registry, call.name)`
  runs after approval. The registry may be rebuilt from the supplement on another node or code
  version.
- **Scenario:** a human approves call X. A redeploy and rehydrate happen in between, and X now
  runs a different implementation registered under the same name. If the tool was removed, the
  `MatchError` fails the whole approved batch (graceful, through `:DOWN`, but the approved and
  held results are lost).
- **Fix:** answer a missing tool with `not_found_result`. Optionally store a tool fingerprint
  (module plus schema hash) at park time and refuse to run on a mismatch.
- **VERIFIED** (code).

### SEC-16. `max_view_chars` is not a hard cap
- **Where:** `lib/normandy/tools/memory/render.ex:74-84`
- **Evidence:** `if used > max_chars and acc != []`: the first line is always included, whatever
  its length.
- **Scenario:** a 100 KB single-line document returns 100 KB from `view`, despite the
  16,000-character limit.
- **Fix:** truncate the first line too, with the same truncation note.
- **VERIFIED**.

### SEC-17. The public registry-based `Executor` APIs bypass policy, approvals, hooks and budget
- **Where:** `lib/normandy/tools/executor.ex:62-72,126-170`
- **Evidence:** `execute/3`, `execute_parallel/3` and `execute_sequential/3` run tools directly.
  No internal caller uses them (checked by grep).
- **Scenario:** a host that wires its own tool loop through these skips every control in
  `Dispatch`.
- **Fix:** deprecate them in 2.0, or document them as "no policy, no hooks".
- **VERIFIED**.

### SEC-18. The Postgres memory store reports NUL bytes in content as "memory store unavailable"
- **Where:** `lib/normandy/tools/memory/commands.ex:435-440` (checks UTF-8 only);
  `lib/normandy/behaviours/memory_store/postgres.ex:224-228`
- **Scenario:** a model `create` containing `\u0000` is valid UTF-8, but a Postgres `text`
  column refuses it. The resulting `Postgrex.Error` reaches the model as a backend outage, and
  the other backends accept the same content. The model may keep retrying.
- **Fix:** refuse `\0` in `Commands.text/3` with `:invalid_input`, for every backend.
- **PLAUSIBLE** (I did not run it; this is standard Postgres behaviour).

---

## Z. Checked and found sound (not findings)

- **Atoms and terms from untrusted data.** Every `String.to_atom` in `lib/` takes
  developer-controlled input (`validate.ex:834`, `hierarchical_coordinator.ex:295`,
  `workflow.ex:558`, registry name generators). Tool input keys are matched against existing
  struct fields, never atomized (`dispatch.ex:475-489`). Every `binary_to_term` uses `[:safe]`.
  OTP-10 is fixed: the Redis registry now uses `[:safe]` and checks `is_pid`. LLM-9 is fixed:
  `AgentMemory.load` only rebuilds `Normandy.Schema` modules and uses `to_existing_atom`. No
  `Code.eval*`. `apply/3` is only called with a configured store module or OTel modules.
- **Memory paths.** `Paths.validate/1` rejects non-UTF-8, Cc/Cf characters, more than 255
  bytes, anything outside `/memories`, `\`, `%`, and empty, `.` or `..` segments. Every command
  validates before calling the store. Renames across mounts are refused. Writes to read-only
  mounts are refused for every write command, including both ends of a rename. The namespace
  comes only from `ctx.values`, and `prepare_input/2` fills `:command` only, so the model cannot
  pick it. Every write path (`create`, `str_replace`, `insert`) checks `max_document_bytes` and
  the cap; `rename` cannot grow content.
- **Injection into stores.** Postgres uses parameterized `$n` throughout; only the table-name
  constant is interpolated. Redis memory keys base64-encode the namespace, and paths are
  validated before being appended after the prefix.
- **Approvals fail closed.** `rejected_calls/2` rejects anything not explicitly `:approve`. The
  synchronous path turns `:needs_approval` into a denial. Approved calls are not
  re-classified, and their input is the stored post-hook input.
- **Policy fails closed.** `apply_policy/4` turns any raise or exit into a denial and names
  only the failure's shape. A malformed `Ruleset` is refused (OTP-7 is fixed).
- **Hooks.** The runner catches exits and throws, and halt reasons reach the model as the
  module or kind only.
- **A2A server.** Failures return `:agent_failed` with no detail (OTP-13 is fixed). The card
  lists no tools by default.
- **MCP and A2A name collisions** return `{:error, {:tool_name_taken, _}}` (OTP-14 is fixed).
- **Malformed LLM output.** A tool name not in the registry gets `not_found_result`. Input
  that is not a JSON object is refused without running the tool (AGENTS-8 is fixed). The JSON
  decoder caps input at 10 MB. Parse-failure logs and telemetry carry sizes, not content.
- **Supervision.** `Turn.Server` effect workers are monitored and unlinked, with a watcher that
  kills the worker if the server dies (AGENTS-13 is fixed). Executor tasks are bounded by
  `Task.yield`/`Task.shutdown`.
- **Secrets.** The `api_key`, `auth_token` and `authorization_token` fields are left out of
  `Inspect`. The client is never persisted in templates. `LLMError` messages exclude the client
  and options.
