# This report needs updating

The submitted final report (`ECE 499 Final Report - Catherine Ye.docx`) describes
**v1 only**. v1 measured **no speedup** (one prefetch per instruction, and in the full
CVA6+Ara system it turned out the predictor almost never fired at all — see below).

Since submission, on branch `caz/pf-v2` (pushed to
`github.com/Malulim/ara-hardware-vector-prefetcher/tree/caz/pf-v2`):

- **Predictor redesign:** streams a whole instruction's worth of addresses instead of
  one element per prediction (commit `63fc63bc`).
- **Capacity:** data buffer and in-flight limit raised so the stream fits
  (`b7915673`).
- **New-instruction detection bug, found via the first full-system run:** the
  predictor detected a new instruction only by its ID changing. Ara's sequencer
  reuses the lowest free instruction ID, so consecutive loads often share an ID —
  `new_insn` fired once across 240 loads in the first full-system run, and zero
  prefetches were issued. Fixed by also treating "a load request appears after a
  cycle without one" as a new instruction (`a2b4615a`).
- **Full-system result (`0cf6794c`):** on the complete CVA6+Ara model, up to
  **1.5x fewer cycles** on a strided-load benchmark, with **98% of prefetches used**.
  Before the detection fix, on and off were identical.

Full numbers and how to reproduce them: `results/README.md` (steps 0-3 and the
full-system runs) on `caz/pf-v2`.

Before citing this report's Results/Limitations sections (predictor behaviour,
"no speedup", open risks), use the branch above instead — the report's Section 5
(Results) and Section 6 (Limitations) are the parts that no longer hold.

Marked 2026-10-18. Not yet rewritten.
