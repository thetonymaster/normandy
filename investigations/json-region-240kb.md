# JSON region extraction: superlinear jump at 240 KB

Started 2026-10-23 (Q). Code at origin/main 792fe79; fixed on branch claude/json-stray-brace.

## FACTS — verified, with evidence

- `bench/json_regions.exs` "balanced in prose", QUICK runs:
  - 120 KB: 5.28 ms, 9.49 MB.
  - 240 KB: 293.83 ms, 205 MB.
  - A second run with Logger at :warning gave 5.38 ms and 303.6 ms.
  - 1 → 30 → 120 KB is about linear (40 µs, 1.31 ms, 5.38 ms).
- "adversarial unclosed": 58.3 ms at 120 KB, 260 ms at 240 KB (4.5x).
- The 240 KB balanced input still binds `{:ok, %{chat_message: "42"}}`. The final reviewer checked this.
- The path is `parse_and_populate/3` → `Decoder.decode` fails → `try_extracted_regions/5`
  (`lib/normandy/llm/json_deserializer.ex:334`). There, `ContentCleaner.balanced_regions/1` is a lazy stream, and each region
  is decoded until one binds, under a decode budget of `8 * size + 1024`.
- `balanced_regions/1` (`lib/normandy/llm/json/content_cleaner.ex`) keeps the maps `memo`, `seen` and `done`. `seen` and `done`
  are keyed per byte position crossed (`trail`), with its own scan budget `work = 8 * size + 1024`.
- The bench's balanced generator puts the answer at byte `div(bytes, 2)` of the filler. That cut is not aligned to
  the 72-byte `prose <> decoy` unit (`bench/json_regions.exs`).

## THEORIES — plausible, unverified

1. **Input artifact.** At 240 KB the half-cut lands inside a decoy and leaves an unclosed `{`/`[` before the answer.
   An unclosed opener triggers a slow path. At 120 KB the cut happens to land between units.
2. **Unclosed-opener slow path in `balanced_regions`.** Once one opener never closes, the per-position `seen`/`trail`
   bookkeeping grows with every later scan, giving quadratic map work and the 205 MB of allocation. This is the real
   cause if theory 1's trigger holds.
3. **Decode cost, not scanning.** Many regions are decoded before the answer. Their summed cost, bounded only at
   8n+1024 bytes, explodes when the region count or nesting changes at 240 KB.
4. **GC / heap threshold.** A process-heap or binary-heap threshold is crossed between 120 and 240 KB, and full-sweep
   GCs dominate. The time would jump, but allocation should not grow 21x.
5. **Budget exhaustion changes the walk.** At 240 KB the `work` budget runs out partway through. The stream ends,
   and something (a retry, or the full-content decode) re-runs.
6. **Sub-binary retention.** `binary_part` sub-binaries keep large binaries alive, or get copied, and the cost changes
   past a refc/heap-binary threshold.

## TESTS
### T1: is the generated input balanced at each size? Sweep 100–260 KB against an aligned control
- Why: theory 1 (input artifact) against 2–6 (the code changes at a size). If only the misaligned inputs jump, size is
  not the trigger.
- Found (ms, `parse_and_validate/2`, single run; `{-}` is the count of `{` minus `}`):
  - Every size from 100 to 260 KB has `{-}` = 0 except 200 and 240 KB, which have 1.
  - generated: 10, 6, 8, 9, 15, **112** (200 KB), 22, **321** (240 KB), 26.
  - aligned control: 5, 6, 14, 15, 17, 21, 23, 24, 26 (linear). All bind `{:ok, _}`.
- Means: the jump happens exactly where the generator leaves one unclosed `{` (a cut inside a decoy). Size alone
  does not do it, so theories 4 and 6 (thresholds) are dead as the trigger. Theory 1 holds as the trigger. The
  mechanism (2, 3 or 5) is still open.
### T2: one stray `{` in an aligned input, by position; scanning against parsing cost
- Why: theory 2 (the scan slows) against 3 (decode slows). The stray goes at the start, just before the answer, or
  just after it (control). Times are for the full parse, for enumerating every region, and for enumerating up to the
  answer region.
- Found (ms at 60 / 120 / 240 KB; the region count is the same with and without the stray: 1253 / 2507 / 5015):
  - parse, no stray: 11.5 / 7.3 / 24.1
  - parse, stray at start: 22.8 / 58.2 / 225.5
  - parse, stray before answer: 14.1 / 33.1 / 154.7
  - parse, stray after answer: 3.5 / 6.9 / 23.9 (control: linear)
  - regions up to the answer, stray at start: 21.5 / 49.2 / 121.0 (no stray: 3.5 / 6.2 / 12.4)
  - all regions, stray anywhere: about 2.5x per doubling, against about 2.2x with no stray
- Means: an unclosed opener *before* the answer slows both the scan and the per-region decode loop. The decode loop
  gets slower although the regions decoded are the same (parse minus scan: 104 ms against 12 ms at 240 KB). That
  points to the cost depending on live state, not on the work done: theory 4 (GC) acting through theory 2 (big
  `seen` state). Theory 5 is unlikely, because the region counts match and the answer is found every time.
### T3: GC counts, and the same run in a process with `min_heap_size: 64M words` (effectively no GC)
- Why: theory 4 (GC) against 2 (the algorithm itself). If the stray cost disappears without GC, GC is the mechanism.
- Found (ms; final heap in words):
  - 60 KB: no stray 12.0, 0.12M words; stray 22.7, 0.20M words. Without GC: 2.4 and 17.2.
  - 120 KB: no stray 6.7; stray 50.6. Without GC: 4.1 and 48.3.
  - 240 KB: no stray 22.7, 0.2M words; stray 234.3, **2.98M words (about 24 MB)**. Without GC: **10.0 and 102.5**.
- Means: theory 4 alone is dead, because without GC the stray still costs about 10x. GC roughly doubles it on top
  (234 against 102 ms at 240 KB), because the live heap is 15x larger. The mechanism is algorithmic and leaves a
  large live state: theory 2 is leading. Theory 3 (decode) is unlikely, since the same regions are decoded.
### T4: `:eprof` on `balanced_regions/1` up to the answer, 240 KB, with and without a leading stray `{`
- Why: theory 2 (the unclosed scan's bookkeeping) against everything else. If the time sits in the `seen` map work,
  theory 2 is confirmed.
- Found:
  - no stray: 26,334 scan steps; `maps:put/3` 31,348 calls (28.7%); total 25.8 ms (profiled).
  - stray: 251,974 scan steps; **`Map.update/4` 245,709 calls (42.6%)**, `Map.get/2` 251,974 (11.3%); total
    220.4 ms (profiled).
- Means: theory 2 is confirmed. The stray's scan runs to EOF, and `unclosed/3` then folds its `trail` (one
  `{opener, pos, in_string?, escape?}` per byte crossed) into `seen` with `Map.update/4`. That is 245K inserts into
  an immutable map, which explains the 205 MB allocated per call (each insert copies a HAMT path) and the 24 MB
  live heap that GC keeps copying afterwards (T3). In this input `seen` is never hit: later scans start at depth 1
  inside decoys the stray's scan crossed at depth 2, and `depth >= min` is false. So the whole map is pure cost.
  Theory 3 is dead (the same regions are decoded; the extra decode-loop time is GC over the big live heap). Theory 5
  is dead (same region counts, the answer is found every time). Theories 4 and 6 are dead as causes; theory 4 only
  amplifies.

## CONCLUSION

The 240 KB "jump" had two parts:

1. **A bench artifact (my bug).** `bench/json_regions.exs`' balanced generator cuts the filler at `div(bytes, 2)`. At
   200 and 240 KB the cut lands inside a decoy, so the "balanced" input carries one unclosed `{` before the answer.
   The label is wrong at those sizes, and the series is not a clean size sweep.
2. **What it exposed is real code behaviour.** One unclosed `{`/`[` anywhere before the JSON answer costs:
   - about 10x the scan work even without GC (102 against 10 ms at 240 KB)
   - one map insert per remaining byte, about 100 bytes of live heap per input byte (about 24 MB at 240 KB)
   - 205 MB allocated per call
   - with GC, 234 against 23 ms at 240 KB

   Time is still roughly linear in size without GC (17 / 48 / 102 ms at 60 / 120 / 240 KB). The superlinear look
   comes from GC copying the growing live map. The Wave 8 guarantee (bytes read ≤ 8n + 1024) holds, but it bounds
   bytes read, not bookkeeping.

Impact: model output with one stray brace in prose before the JSON (`use {name} as a placeholder ...`) takes this
path. At typical answer sizes (≤ 30 KB) that is about 20 ms per parse attempt (up to 3 attempts). It matters for
large outputs.

### Five whys (why was this breakable?)

1. Why is a stray brace expensive? Its scan reads to EOF and records every byte it crossed into `seen`.
2. Why every byte? `seen` is the Wave 8 fix that made the adversarial case linear: a later scan stops when it
   reaches a lexer state `{opener, pos, in_string?, escape?}` that an unclosed scan crossed with no more openers
   pending.
3. Why must it be every byte? It needn't. Scanning is deterministic from `(pos, lexer state)`, so a later scan that
   joins the earlier scan's path reaches the next recorded checkpoint anyway. Sparse checkpoints would keep the
   short-cut: for example only bytes where the state or depth changes (openers, closers, quotes), or every k bytes.
4. Why wasn't it caught? The fix and its tests were judged on the stated guarantee, bytes read ≤ 8n + 1024. Memory,
   map operations and wall time were not measured, and the repo had no benchmark until #50.
5. Why was that possible? The complexity contract counts the cheap operation (a byte read, about 0.03 µs) and leaves
   out the expensive one it triggers (a map insert, about 0.4 µs, plus about 100 bytes of live heap). A contract
   that bounds only part of the work lets the unbounded part grow.

### Fix (Q chose both, 2026-10-24)

- **Bench:** `bench/json_regions.exs` now cuts the balanced input on whole units, and asserts every brace closes at
  every size. It also has a fixed-name "one stray opener" scenario: `"Use { to open a block. "` plus the balanced
  input.
- **Code:** `ContentCleaner` looks up `done`/`seen`, and keeps `trail`, only at *marked* states: a scan's first byte,
  and bytes where its lexer state or depth changed. A `mark?` flag was added to the lexer tuple. Between marks the
  state only moves forward over plain bytes, and two scans on one path change state at the same bytes, so a joining
  scan still meets a recorded mark at most one plain run later. The 8n + 1024 read budget is unchanged, and every
  Wave 8 adversarial test passes.
- **Test:** `json_deserializer_test.exs` "one stray opener before 200 KB of prose parses in a bounded heap" runs the
  parse under `max_heap_size: 3M words`. The old code is killed (it needs 6–12M words); the new code passes (under
  1.5M). A reductions-ratio test was tried first and dropped: BIF map operations count few reductions, so the ratio
  was 3.7x old against 2.9x new, with no clean separation.

### Result (`BENCH_COMPARE=before`, full mode, M4 Pro)

| 240 KB | before | after |
|---|---|---|
| balanced in prose | 22.3 ms, 19.9 MB | 7.8 ms, 6.1 MB |
| one stray opener | 217.7 ms, 191 MB | 17.9 ms, 20.2 MB |
| adversarial unclosed | 268.3 ms, 208 MB | 164.7 ms, 118 MB |

At 30 / 120 KB the stray opener went from 8.8 / 108.9 ms to 1.05 / 8.6 ms. The stray now costs about 2.3x
balanced: the remaining cost is the one pass to EOF that tells it the brace never closes.
