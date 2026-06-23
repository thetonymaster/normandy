# Normandy Multi-Agent Demo Video — Design

**Date:** 2026-06-19
**Status:** Approved (design), pending implementation plan
**Author:** Brainstormed with Q

## Goal

Produce a short terminal screencast of the `customer_support_app` example CLI that
shows a single support conversation **routing live across all four Normandy agents**
(Greeter → Order → Technical → Billing), with a real tool call and a closing
`/stats` reveal. This is a follow-up artifact to the existing `marketing/linkedin-1.0`
carousel announcing Normandy 1.0.

The demo is rendered deterministically with [VHS](https://github.com/charmbracelet/vhs)
from a `.tape` script, driving a **real** `iex -S mix` session against the **live**
Anthropic Claude API.

## Deliverables

Two artifacts produced from the same demo driver, written to `marketing/demo-1.0/`:

| File | Format | Length | Venue |
|---|---|---|---|
| `normandy-demo.mp4` | 16:9 mp4 | ~60–75s | LinkedIn (feed inline) |
| `normandy-demo.gif` | looping gif | ~20–30s (trimmed) | README / hexdocs |

Plus the VHS source kept in-repo for reproducibility:
- `marketing/demo-1.0/normandy-demo.tape` (full → mp4)
- `marketing/demo-1.0/normandy-demo-short.tape` (beats 1–2 → gif)

## Prerequisites (hard blockers — resolve before rendering)

1. **VHS installed.** Not currently present. macOS: `brew install vhs` (Homebrew
   pulls `ffmpeg` + `ttyd` as dependencies — both also currently missing). No
   alternative renderer will be silently substituted.
2. **`ANTHROPIC_API_KEY` available in the render shell.** The live-API path requires
   it; `ChatSession.create_llm_client/0` reads `System.get_env("ANTHROPIC_API_KEY")`
   and warns (then agents fail) if unset. Not set in the current shell.
3. **Example app compiles and boots** (`cd examples/customer_support_app && mix deps.get && mix compile`).
   `deps/` and `_build/` already exist from prior runs.

## What we record

### Vehicle
The existing `examples/customer_support_app` CLI (`CustomerSupport.CLI.start/0`),
an interactive REPL over a multi-agent supervision tree with ETS-backed stores.

### The one code change (presentation layer only)
Routing is decided in `ChatSession.determine_agent/2` and stored per-message in
history under the `:agent` key, but the CLI's `send_and_display/2` prints a bare
`Agent:` prefix and `send_message/2` returns only `{:ok, response_text}` — the
handling agent is invisible inline.

**Change:** modify **only `cli.ex`'s `send_and_display/2`** to read the handling
agent from the session history (last `:assistant` entry's `:agent`) and render an
inline tag, e.g. `Agent [Order Support]:`. Reuse the existing `format_role/2`
agent-name mapping for consistency.

**Explicitly not changed:** the public `send_message/2` `{:ok, response}` contract
(documented in README + `examples/README.md`), the agent prompts, and the routing
logic. This keeps the change to the presentation layer and preserves the documented
API (Chesterton's fence).

The `/stats` command already prints "Agents used: …" unmodified and serves as the
closing reveal.

### Logger noise
Quiet the Logger to `:warning` for the recording (via the example's
`config/dev.exs` or a `Logger.configure(level: :warning)` at CLI start) so
`Logger.info` lines ("Created session", "OrderStore initialized with sample data",
"ChatSession initialized") don't clutter the frame. Scope this so it only affects
the demo, not the example's normal behavior, if reasonable.

## Storyboard (deterministic routing path)

Routing is **provably deterministic** — `GreeterAgent.classify_query/1` is pure
keyword matching and `ChatSession.determine_agent/2` only re-routes away from a
specialist when `changing_topic?/1` matches phrases like "different question" /
"also need help with". Response **text** is genuinely live from Claude; only the
**routing path** is fixed.

| Beat | Typed input | Routes to | Mechanism (verified in code) |
|---|---|---|---|
| 1 | `Hi! I've got a couple questions about my TechStore account.` | **Greeter** | no keywords → `:general` → greeter |
| 2 | `Can you track my order ORD-12345?` | **Order Support** | current=greeter reclassifies; "track"/"order" → `:order`; **fires `OrderLookupTool`** on seed order ORD-12345 (status `shipped`, tracking `TRK-ABC123`) |
| 3 | `I have a different question — my wireless headphones aren't working.` | **Technical Support** | "different question" → re-route; "not working" → `:technical` |
| 4 | `I also need help with a refund on order ORD-11111.` | **Billing Support** | "also need help with" → re-route; "refund" → `:billing` |
| 5 | `/stats` | — | reveals "Agents used: Greeter, Order Support, Technical Support, Billing Support" |

Seed data referenced is real (`order_store.ex` `seed_sample_data/0`): ORD-12345
(shipped, TRK-ABC123) and ORD-11111 (delivered, Mechanical Keyboard).

## Render pipeline

- **Pacing via `Wait+Screen`** on the inline `Agent [` tag rather than fixed
  `Sleep`s, so variable live-API latency never desyncs the typing from the output.
  Boot waits: iex prompt before launching the CLI; the `You:` prompt / banner
  before the first message.
- **Full tape → mp4:** all five beats. Terminal dimensions tuned for 16:9 and
  mobile legibility (wide enough to avoid wrapping long Claude responses).
- **Short tape → gif:** beats 1–2 only (Greeter greet + Order Support with a live
  tool call), kept short to bound gif file size.
- **Theme:** a clean dark VHS theme + a legible monospace font.

## Risks

- **Live-API non-determinism / length float** — Wait-gating absorbs timing drift;
  mp4 length will float ~±15s around target. Acceptable.
- **Response wrapping on 16:9** — long Claude replies may wrap/scroll. Mitigate by
  tuning terminal width/height first; only if wrapping still looks bad, nudge
  `output_instructions` toward brevity (do not pre-emptively touch agent prompts).
- **Gif size** — a 60s terminal gif is large; this is why the gif is a separate
  trimmed tape rather than a second `Output` line on the full tape.
- **API cost/flakiness on retakes** — each render makes 4 real Claude calls;
  retakes cost tokens. Capture a known-good run before re-tuning.

## Out of scope

- Voiceover / webcam / captions (terminal-only recording).
- Square 1:1 variant.
- Any change to Normandy core library code (only the example CLI presentation layer
  and the example's demo config are touched).
