# Normandy Multi-Agent Demo Video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a short terminal screencast (mp4 + gif) of the `customer_support_app` CLI routing a single live conversation across all four Normandy agents (Greeter → Order → Technical → Billing) with a real tool call and a `/stats` reveal.

**Architecture:** A VHS `.tape` script drives a real `iex -S mix` session of the existing example app against the live Anthropic Claude API. A small presentation-layer change to `cli.ex` surfaces the handling agent inline per turn (`Agent [Order Support]:`). Routing is deterministic (keyword-based), so the agent path is guaranteed; only response text is live. Two tapes produce a full mp4 (LinkedIn) and a trimmed gif (README).

**Tech Stack:** Elixir/Mix, Normandy, Anthropic Claude (live), [VHS](https://github.com/charmbracelet/vhs) (+ `ffmpeg`, `ttyd`), Homebrew.

## Global Constraints

- Spec of record: `docs/superpowers/specs/2026-06-19-normandy-demo-video-design.md`.
- Only the example app's **presentation layer** is touched (`examples/customer_support_app/lib/customer_support/cli.ex`) — NOT the public `send_message/2` `{:ok, response}` contract, NOT agent prompts, NOT routing logic, NOT Normandy core.
- Outputs live in `marketing/demo-1.0/` (consistent with existing `marketing/linkedin-1.0/`).
- `vhs` is always invoked **from the repository root** so `Output` paths resolve correctly.
- Live API: the app reads `System.get_env("ANTHROPIC_API_KEY")`, but the key is present in the environment as **`API_KEY`** (len 108, visible to Bash). Bridge it at render time in the same command: `ANTHROPIC_API_KEY="$API_KEY" vhs …` (env does not persist across separate Bash calls). Each full render makes ~4 real Claude calls — capture a known-good run before re-tuning.
- VHS 0.11.0 confirmed installed (with `ffmpeg` + `ttyd`); `vhs validate`, `Require`, and `Wait[+Screen][@<timeout>] /<regexp>/` are all supported. Task 1 install steps are already satisfied.
- Agent display-name mapping is the single source of truth: `:greeter`→`"Greeter"`, `:order_support`→`"Order Support"`, `:technical_support`→`"Technical Support"`, `:billing_support`→`"Billing Support"`, anything else→`"Agent"`.

---

### Task 1: Prerequisites & environment baseline

**Files:** none modified (environment + verification only).

**Interfaces:**
- Produces: a verified toolchain (`vhs`, `ffmpeg`, `ttyd` on PATH), a compiled example app, and a known `mix test` baseline for later tasks.

- [ ] **Step 1: Install VHS and its dependencies**

Run:
```bash
brew install vhs
```
Expected: Homebrew installs `vhs` and pulls `ffmpeg` + `ttyd` as dependencies.

- [ ] **Step 2: Verify the toolchain is on PATH**

Run:
```bash
vhs --version && ffmpeg -version | head -1 && ttyd --version
```
Expected: a VHS version line, an ffmpeg version line, and a ttyd version line — no "command not found".

- [ ] **Step 3: Verify the API key is present (as `API_KEY`)**

Run:
```bash
[ -n "$API_KEY" ] && echo "API_KEY present (len ${#API_KEY})" || echo "MISSING"
```
Expected: `API_KEY present (len 108)`. The app reads `ANTHROPIC_API_KEY`, so Task 6 bridges `API_KEY`→`ANTHROPIC_API_KEY` inline at render time. If `MISSING`, STOP and ask Q — the live-API render cannot proceed without it.

- [ ] **Step 4: Build the example app**

Run:
```bash
cd examples/customer_support_app && mix deps.get && mix compile
```
Expected: dependencies resolved and compilation succeeds (warnings OK).

- [ ] **Step 5: Capture the test baseline (surface, don't silently fix)**

Run:
```bash
cd examples/customer_support_app && mix test
```
Expected: Record the result. The pre-existing `test "greets the world"` asserts `CustomerSupport.hello() == :world`, but `customer_support.ex` defines no `hello/0` — this test is expected to FAIL. Do NOT fix it as part of this plan. Note it in the handoff and ask Q whether to address the example's pre-existing failing test separately. Task 2 isolates new tests in their own file so they pass independently of this.

- [ ] **Step 6: Checkpoint**

No commit (environment setup). Confirm: VHS present, key present, example compiles, baseline recorded. Then proceed.

---

### Task 2: Inline agent label in the CLI (TDD)

**Files:**
- Create: `examples/customer_support_app/test/cli_test.exs`
- Modify: `examples/customer_support_app/lib/customer_support/cli.ex` (add `agent_display_name/1`, add `current_agent_label/1`, refactor `format_role/2`, update `send_and_display/2`)

**Interfaces:**
- Produces: `CustomerSupport.CLI.agent_display_name/1` — public, maps an agent type atom to a display string per the Global Constraints mapping. Consumed by `format_role/2` and `current_agent_label/1`, and asserted by the test.

- [ ] **Step 1: Write the failing test**

Create `examples/customer_support_app/test/cli_test.exs`:
```elixir
defmodule CustomerSupport.CLITest do
  use ExUnit.Case, async: true

  alias CustomerSupport.CLI

  describe "agent_display_name/1" do
    test "maps each agent type to its display name" do
      assert CLI.agent_display_name(:greeter) == "Greeter"
      assert CLI.agent_display_name(:order_support) == "Order Support"
      assert CLI.agent_display_name(:technical_support) == "Technical Support"
      assert CLI.agent_display_name(:billing_support) == "Billing Support"
    end

    test "falls back to \"Agent\" for unknown types" do
      assert CLI.agent_display_name(:something_else) == "Agent"
      assert CLI.agent_display_name(nil) == "Agent"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd examples/customer_support_app && mix test test/cli_test.exs
```
Expected: FAIL — `function CustomerSupport.CLI.agent_display_name/1 is undefined or private`.

- [ ] **Step 3: Add the public mapping and refactor `format_role/2`**

In `examples/customer_support_app/lib/customer_support/cli.ex`, add the public function (place it just above `defp format_role`):
```elixir
  @doc false
  def agent_display_name(:greeter), do: "Greeter"
  def agent_display_name(:order_support), do: "Order Support"
  def agent_display_name(:technical_support), do: "Technical Support"
  def agent_display_name(:billing_support), do: "Billing Support"
  def agent_display_name(_), do: "Agent"
```

Replace the existing `format_role(:assistant, agent)` clause:
```elixir
  defp format_role(:assistant, agent) do
    agent_name =
      case agent do
        :greeter -> "Greeter"
        :order_support -> "Order Support"
        :technical_support -> "Technical Support"
        :billing_support -> "Billing Support"
        _ -> "Agent"
      end

    IO.ANSI.cyan() <> "[#{agent_name}]" <> IO.ANSI.reset()
  end
```
with the DRY version:
```elixir
  defp format_role(:assistant, agent) do
    IO.ANSI.cyan() <> "[#{agent_display_name(agent)}]" <> IO.ANSI.reset()
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd examples/customer_support_app && mix test test/cli_test.exs
```
Expected: PASS (2 tests, 0 failures).

- [ ] **Step 5: Surface the handling agent inline in `send_and_display/2`**

In `cli.ex`, replace the existing `send_and_display/2`:
```elixir
  defp send_and_display(session_id, message) do
    IO.write(IO.ANSI.cyan() <> "Agent: " <> IO.ANSI.reset())
    IO.write("(thinking...)")

    case CustomerSupport.send_message(session_id, message) do
      {:ok, response} ->
        # Clear the "thinking..." message
        IO.write("\r" <> String.duplicate(" ", 80) <> "\r")
        IO.puts(IO.ANSI.cyan() <> "Agent: " <> IO.ANSI.reset() <> response)
        IO.puts("")

      {:error, reason} ->
        IO.write("\r" <> String.duplicate(" ", 80) <> "\r")
        IO.puts(IO.ANSI.red() <> "Error: #{inspect(reason)}" <> IO.ANSI.reset())
        IO.puts("")
    end
  end
```
with the version that reads the handling agent from history (no public-API change):
```elixir
  defp send_and_display(session_id, message) do
    IO.write(IO.ANSI.cyan() <> "Agent: " <> IO.ANSI.reset())
    IO.write("(thinking...)")

    case CustomerSupport.send_message(session_id, message) do
      {:ok, response} ->
        label = current_agent_label(session_id)
        # Clear the "thinking..." message
        IO.write("\r" <> String.duplicate(" ", 80) <> "\r")
        IO.puts(IO.ANSI.cyan() <> "Agent [#{label}]: " <> IO.ANSI.reset() <> response)
        IO.puts("")

      {:error, reason} ->
        IO.write("\r" <> String.duplicate(" ", 80) <> "\r")
        IO.puts(IO.ANSI.red() <> "Error: #{inspect(reason)}" <> IO.ANSI.reset())
        IO.puts("")
    end
  end

  defp current_agent_label(session_id) do
    case CustomerSupport.get_history(session_id) do
      {:ok, history} ->
        history
        |> Enum.reverse()
        |> Enum.find(fn entry -> entry.role == :assistant end)
        |> case do
          %{agent: agent} -> agent_display_name(agent)
          _ -> "Agent"
        end

      _ ->
        "Agent"
    end
  end
```

- [ ] **Step 6: Confirm it compiles and tests still pass**

Run:
```bash
cd examples/customer_support_app && mix format && mix compile && mix test test/cli_test.exs
```
Expected: formats clean, compiles, 2 tests pass.

- [ ] **Step 7: Commit**

```bash
git add examples/customer_support_app/lib/customer_support/cli.ex examples/customer_support_app/test/cli_test.exs
git commit -m "feat(example): show handling agent inline in support CLI"
```

---

### Task 3: Quiet the Logger during the demo

**Files:**
- Modify: `examples/customer_support_app/lib/customer_support/cli.ex` (`start/0`)

**Interfaces:**
- Consumes: nothing new. Produces: a clean frame (no `[info]` lines) for the recording, scoped to the CLI run only.

- [ ] **Step 1: Lower the log level at CLI start**

In `cli.ex`, at the very top of `start/0` (before `print_banner()`), add:
```elixir
  def start do
    Logger.configure(level: :warning)
    print_banner()
```
(Leave the rest of `start/0` unchanged. `require Logger` is already present at the top of the module.)

- [ ] **Step 2: Verify boot is quiet (no API needed)**

Run:
```bash
cd examples/customer_support_app && echo '/quit' | iex -S mix -e "CustomerSupport.CLI.start()"
```
Expected: banner + "✓ Connected to support…" appear with NO `[info]` lines (e.g. no "OrderStore initialized with sample data", "ChatSession initialized", "Created session"). The session boots, `/quit` ends it. (This boots stores but makes no Claude call.)

- [ ] **Step 3: Commit**

```bash
git add examples/customer_support_app/lib/customer_support/cli.ex
git commit -m "chore(example): quiet logger during CLI demo session"
```

---

### Task 4: Full demo tape (mp4)

**Files:**
- Create: `marketing/demo-1.0/normandy-demo.tape`

**Interfaces:**
- Consumes: the inline-label CLI (Task 2) and quiet logger (Task 3). Produces (when rendered in Task 6): `marketing/demo-1.0/normandy-demo.mp4`. Wait-anchors rely on the unique per-turn labels `Greeter]`, `Order Support]`, `Technical Support]`, `Billing Support]`.

- [ ] **Step 1: Create the output directory**

Run:
```bash
mkdir -p marketing/demo-1.0
```
Expected: directory exists.

- [ ] **Step 2: Write the full tape**

Create `marketing/demo-1.0/normandy-demo.tape`:
```tape
# Normandy multi-agent demo — full conversation → mp4
# Render from the REPOSITORY ROOT:  vhs marketing/demo-1.0/normandy-demo.tape
# Requires ANTHROPIC_API_KEY in the environment (live Claude API).

Output marketing/demo-1.0/normandy-demo.mp4

Require iex

Set Shell "zsh"
Set FontSize 22
Set Width 1280
Set Height 720
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 55ms
Set WaitTimeout 90s

# --- Boot the example app ---
Type "cd examples/customer_support_app" Enter
Sleep 1s
Type "iex -S mix" Enter
Wait+Screen /iex\(1\)>/
Sleep 1s

# --- Launch the multi-agent support CLI ---
Type "CustomerSupport.CLI.start()" Enter
Wait+Screen /You:/
Sleep 1500ms

# --- Beat 1: Greeter (general greeting, no keywords) ---
Type "Hi! I've got a couple questions about my TechStore account." Enter
Wait+Screen /Greeter\]/
Sleep 2s

# --- Beat 2: Order Support (fires OrderLookupTool on ORD-12345) ---
Type "Can you track my order ORD-12345?" Enter
Wait+Screen /Order Support\]/
Sleep 2500ms

# --- Beat 3: Technical Support ("different question" re-routes; "not working") ---
Type "I have a different question, my wireless headphones aren't working." Enter
Wait+Screen /Technical Support\]/
Sleep 2500ms

# --- Beat 4: Billing Support ("also need help with" re-routes; "refund") ---
Type "I also need help with a refund on order ORD-11111." Enter
Wait+Screen /Billing Support\]/
Sleep 2500ms

# --- Beat 5: routing reveal ---
Type "/stats" Enter
Wait+Screen /Agents used/
Sleep 4s

# --- Exit cleanly ---
Type "/quit" Enter
Sleep 2s
```

- [ ] **Step 3: Validate tape syntax (no render, no API)**

Run:
```bash
vhs validate marketing/demo-1.0/normandy-demo.tape
```
Expected: no errors. (If your VHS build lacks a `validate` subcommand, instead confirm there are no typos by re-reading the tape; rendering in Task 6 will surface any parse error.)

- [ ] **Step 4: Commit the tape**

```bash
git add marketing/demo-1.0/normandy-demo.tape
git commit -m "feat(marketing): VHS tape for full Normandy multi-agent demo (mp4)"
```

---

### Task 5: Trimmed demo tape (gif)

**Files:**
- Create: `marketing/demo-1.0/normandy-demo-short.tape`

**Interfaces:**
- Consumes: same CLI as Task 4. Produces (when rendered in Task 6): `marketing/demo-1.0/normandy-demo.gif` — beats 1–2 only (Greeter greet + Order Support live tool call), smaller dimensions to bound gif file size.

- [ ] **Step 1: Write the short tape**

Create `marketing/demo-1.0/normandy-demo-short.tape`:
```tape
# Normandy multi-agent demo — trimmed (beats 1-2) → looping gif for README
# Render from the REPOSITORY ROOT:  vhs marketing/demo-1.0/normandy-demo-short.tape
# Requires ANTHROPIC_API_KEY in the environment (live Claude API).

Output marketing/demo-1.0/normandy-demo.gif

Require iex

Set Shell "zsh"
Set FontSize 18
Set Width 1000
Set Height 560
Set Padding 20
Set Theme "Dracula"
Set TypingSpeed 55ms
Set WaitTimeout 90s

# --- Boot + launch ---
Type "cd examples/customer_support_app" Enter
Sleep 1s
Type "iex -S mix" Enter
Wait+Screen /iex\(1\)>/
Sleep 1s
Type "CustomerSupport.CLI.start()" Enter
Wait+Screen /You:/
Sleep 1500ms

# --- Beat 1: Greeter ---
Type "Hi! I've got a question about my TechStore order." Enter
Wait+Screen /Greeter\]/
Sleep 2s

# --- Beat 2: Order Support (live tool call) ---
Type "Can you track my order ORD-12345?" Enter
Wait+Screen /Order Support\]/
Sleep 3s
```
Note: Beat 1 here avoids order keywords landing on the greeter? It contains "order", which classifies to `:order`. That is intended — for the short gif we still want the greeter first. To guarantee Greeter on beat 1, the message must contain NO routing keywords. Replace beat-1 line with a keyword-free greeting:
```tape
Type "Hi there! I have a couple of questions for TechStore." Enter
```
(Use this keyword-free version so beat 1 routes to Greeter, then beat 2's "track my order" routes to Order Support.)

- [ ] **Step 2: Validate tape syntax**

Run:
```bash
vhs validate marketing/demo-1.0/normandy-demo-short.tape
```
Expected: no errors (or re-read per Task 4 Step 3 note).

- [ ] **Step 3: Commit the tape**

```bash
git add marketing/demo-1.0/normandy-demo-short.tape
git commit -m "feat(marketing): trimmed VHS tape for Normandy demo gif"
```

---

### Task 6: Render and verify the videos (live API)

**Files:**
- Produces: `marketing/demo-1.0/normandy-demo.mp4`, `marketing/demo-1.0/normandy-demo.gif`

**Interfaces:**
- Consumes: both tapes, the modified CLI, a valid `ANTHROPIC_API_KEY`. This is the only task that makes live Claude calls.

- [ ] **Step 1: Render the mp4 from repo root (bridging the key inline)**

Run:
```bash
[ -n "$API_KEY" ] && ANTHROPIC_API_KEY="$API_KEY" vhs marketing/demo-1.0/normandy-demo.tape
```
Expected: VHS boots the app, drives all five beats, writes `marketing/demo-1.0/normandy-demo.mp4`. If a `Wait+Screen` times out, the agent label for that turn never appeared — STOP and inspect (wrong routing keyword, API error, or label mismatch) rather than re-running blindly.

- [ ] **Step 2: Render the gif from repo root (bridging the key inline)**

Run:
```bash
ANTHROPIC_API_KEY="$API_KEY" vhs marketing/demo-1.0/normandy-demo-short.tape
```
Expected: writes `marketing/demo-1.0/normandy-demo.gif`.

- [ ] **Step 3: Verify the artifacts exist and are sane**

Run:
```bash
ls -lh marketing/demo-1.0/normandy-demo.mp4 marketing/demo-1.0/normandy-demo.gif
ffprobe -v error -show_entries format=duration:stream=width,height -of default=noprint_wrappers=1 marketing/demo-1.0/normandy-demo.mp4
```
Expected: both files exist and are non-zero. mp4 is 1280x720, duration ~60–75s (will float with API latency). Gif file size is reasonable for a README (ideally < ~8 MB; if much larger, reduce `Width`/`Height`/`FontSize` or trim a beat in the short tape and re-render).

- [ ] **Step 4: Human review checkpoint (Q)**

Open the mp4 and gif. Confirm: each turn shows the correct inline agent tag (`Greeter` → `Order Support` → `Technical Support` → `Billing Support`), the Order Support turn references real order data (ORD-12345 / TRK-ABC123), `/stats` lists all four agents, no `[info]` log noise, and no bad text wrapping. If wrapping looks bad, tune `Width`/`Height`/`FontSize` in the tape and re-render (re-runs cost API calls). Do not commit binaries until Q approves.

- [ ] **Step 5: Commit the rendered media**

```bash
git add marketing/demo-1.0/normandy-demo.mp4 marketing/demo-1.0/normandy-demo.gif
git commit -m "feat(marketing): rendered Normandy multi-agent demo video (mp4 + gif)"
```
(Committing media matches the existing `marketing/linkedin-1.0/` convention, which checks in PNGs and a PDF.)

---

### Task 7 (optional): Embed the gif in the README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `marketing/demo-1.0/normandy-demo.gif`. Produces: a visible demo near the top of the README.

- [ ] **Step 1: Add the gif under the intro**

In `README.md`, immediately after the badges/intro paragraph and before `## Features`, add:
```markdown
![Normandy multi-agent customer support demo](marketing/demo-1.0/normandy-demo.gif)
```

- [ ] **Step 2: Verify the path resolves**

Run:
```bash
test -f marketing/demo-1.0/normandy-demo.gif && grep -q "normandy-demo.gif" README.md && echo OK
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): embed multi-agent demo gif"
```

---

## Self-Review

**Spec coverage:**
- Deliverables (mp4 + gif in `marketing/demo-1.0/`) → Tasks 4, 5, 6. ✓
- VHS install prerequisite → Task 1. ✓
- `ANTHROPIC_API_KEY` live-API prereq → Task 1 (verify) + Task 6 (use). ✓
- Inline agent tag, presentation layer only, public API untouched → Task 2. ✓
- `/stats` final reveal → Task 4 beat 5 (no code change needed; existing command). ✓
- Logger quieting, scoped to demo → Task 3. ✓
- Deterministic routing storyboard (Greeter→Order→Technical→Billing) → Task 4 beats with verified keyword/`changing_topic?` triggers. ✓
- Tool call on real seed data (ORD-12345) → Task 4 beat 2. ✓
- Trimmed gif as separate tape (size control) → Task 5. ✓
- Wait-gating on inline labels for live-latency robustness → Tasks 4/5. ✓
- README/hexdocs gif use → Task 7 (optional embed). ✓
- Risk: response wrapping → Task 6 Step 4 review + tune. ✓

**Placeholder scan:** No TBD/TODO; every code/step shows concrete content. The only conditional is the `vhs validate` fallback (handled explicitly) and the gif-size tuning guidance (concrete thresholds + actions). ✓

**Type consistency:** `agent_display_name/1` defined in Task 2 and reused by `format_role/2` and `current_agent_label/1`; display strings (`"Greeter"`, `"Order Support"`, `"Technical Support"`, `"Billing Support"`) match the Wait-anchor regexes (`Greeter]`, `Order Support]`, etc.) in Tasks 4/5. ✓

## Known issues surfaced to Q (not fixed by this plan)
- The example's pre-existing `test "greets the world"` (`test/customer_support_test.exs`) asserts `CustomerSupport.hello() == :world`, but no `hello/0` exists — likely already failing. New tests are isolated in `test/cli_test.exs`. Decide separately whether to repair or remove the placeholder test.
