# Normandy Agent Horde — Screen-Recording Script

A shot-by-shot guide for recording the multi-agent "horde" demo. You drive the
terminal at human pace; everything here is verified against real live runs.

**What it shows:** one research question → ~13 Normandy agents fan out across
**3 search engines + Firecrawl** and **3 LLM providers (Claude · GPT-4o · Llama
on DigitalOcean)** in parallel → a synthesized, cited Markdown report saved
locally. The star beat is stage ⑤ — three different providers analyzing in
parallel through one provider-agnostic Normandy adapter.

---

## 0. One-time setup (before you hit record)

**Env vars** — all 8 must be exported in the shell you record in:
```
ANTHROPIC_API_KEY   OPENAI_API_KEY   DO_INFERENCE_KEY   DO_INFERENCE_URL
EXA_API_KEY   SERPAPI_API_KEY   SERPER_API_KEY   FIRECRAWL_API_KEY
```
Quick check (should print 8): `for v in ANTHROPIC_API_KEY OPENAI_API_KEY DO_INFERENCE_KEY DO_INFERENCE_URL EXA_API_KEY SERPAPI_API_KEY SERPER_API_KEY FIRECRAWL_API_KEY; do printenv $v >/dev/null && echo "$v ok"; done | wc -l`

**Pre-compile** so the first frame is clean (no "Compiling…" noise):
```
cd examples/agent_horde && mix compile
```

**Terminal look:**
- Font: a legible mono (JetBrains Mono / Menlo), size ~18–20.
- Window: 16:9, ~110 cols × ~32 rows. Dark theme (Dracula / One Dark).
- Clear scrollback right before recording (`Cmd-K`) so the banner is frame one.

**Clear old reports** (so the reveal shows exactly one fresh file):
```
rm -f examples/agent_horde/reports/*.md
```

---

## 1. The command (type this on camera)

From `examples/agent_horde/`:
```
mix run -e 'AgentHorde.CLI.start()'
```
The banner + `🧠 Ask the horde:` prompt appear in ~1s (already compiled).

## 2. The question (type at the prompt)

Recommended (returns rich, well-sourced results — verified):
> **What makes the Rust programming language memory-safe?**

Good alternates (all verified to produce clean cited reports):
- "What is the Elixir programming language particularly good for?"
- "How does the Raft consensus algorithm work?"
- "What are the main tradeoffs between gRPC and REST?"

Pick a question whose answer lives in good public docs — the scrape + citations
look best when the top sources are authoritative (official docs, Wikipedia,
high-quality blogs).

---

## 3. Beat-by-beat (what appears, ~50s total live)

Each stage prints one line with an elapsed-ms suffix. Exact on-camera text:

| Beat | Line on screen | ~secs | Caption / voiceover idea |
|---|---|---|---|
| ① | `▸ ① Planner → 3 queries` | 2–4s | "A planner agent breaks the question into search queries." |
| ② | `▸ ② Searching: Exa · SerpAPI · Serper (parallel) → 14 sources` | 3–6s | "Three search engines hit **in parallel** — Exa, SerpAPI, Serper." |
| ③ | `▸ ③ Curator → 4 sources selected` | 3–5s | "A curator agent dedups and picks the best sources." |
| ④ | `▸ ④ Scraping 4 pages with Firecrawl (parallel)` | 4–8s | "Firecrawl pulls the full text of each page, in parallel." |
| ⑤ | `▸ ⑤ Analyzing on Claude · GPT-4o · Llama [DO] (parallel) → 3 analyses` | 8–20s | **★ THE MONEY SHOT** — "Three different LLM providers analyze the same evidence at once — Claude, GPT-4o, and Llama on DigitalOcean — all through one Normandy adapter." |
| ⑥ | `▸ ⑥ Editor → synthesizing report (1876 bytes)` | 5–10s | "An editor agent fuses the three analyses into one cited report." |
| ⑦ | `▸ ⑦ Wrote report → reports/<slug>-<ts>.md` | <1s | "Saved to a local Markdown file." |

Then the CLI prints a divider, the **full report inline**, another divider, and
`📄 Saved to: reports/…md`, then re-prompts `🧠 Ask the horde:`.

Type `/quit` → it prints `Bye!` and exits cleanly.

---

## 4. The reveal

After `/quit`, show the artifact two ways:
1. The report already printed inline above the prompt — scroll up through it
   slowly. It has: a title, a 2–3 sentence summary, **Key Findings** bullets,
   and a **Sources** list of the real URLs that were scraped.
2. Optionally `cat` / open the file to prove it's a real saved artifact:
   ```
   cat reports/*.md
   ```
   (or open it in your editor's Markdown preview for a polished look).

---

## 5. Editing notes

- **Total target:** 60–90s. The live run is ~50s; trim/ramp the waits.
- **Speed-ramp the latency**, don't cut it — a 2–4× speed-up over the gaps
  between ② and ⑥ keeps the "real work happening" feel while staying tight.
  Stage ⑤ is the longest; ramp it but let the **⑤ line itself land at full
  speed** so viewers read "Claude · GPT-4o · Llama".
- **Hold on ⑤** (the multi-provider line) for an extra beat — that's the thesis
  of the whole demo. Consider a caption overlay: *"3 providers · 1 abstraction."*
- **Hold on the report** + **Sources** for ~3s so the citations register as real.
- Optional opener card (0:00–0:03): *"Normandy — multi-agent research horde
  · 13 agents · 7 live services · Claude + GPT-4o + Llama."*
- Optional closer card: *"One question in. A cited report out. Built on
  Normandy."* + repo/link.
- This pairs with the existing `marketing/linkedin-1.0` 1.0 carousel as the
  motion follow-up.

---

## 6. If a take goes wrong

- A provider can occasionally drop (rate limit / hiccup); the horde is
  **fail-slow** — if ⑤ shows `→ 2 analyses` instead of 3, just re-run; the run
  still completes, but for the hero take you want all three.
- Re-running is cheap (~50s, a few cents). Clear `reports/` between takes so the
  reveal shows one file.
- First run after a code change recompiles — always `mix compile` once before
  recording so the first frame is the banner, not "Compiling…".
