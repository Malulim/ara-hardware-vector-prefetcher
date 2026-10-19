# Prefetcher measurements

On/off comparisons of the prefetcher, one set of files per design step.

## How these numbers are produced

`hardware/tb/unit/pf_system_tb.sv` wraps the real `prefetch_buffer.sv` in
behavioural models of the dispatcher, `addrgen`, `vldu` and memory, and runs
64 back-to-back strided loads over one array. `hardware/tb/unit/pf_sweep.py`
sweeps vector length, memory latency `L` and the gap between instructions, in
three modes:

| Mode | Meaning |
|---|---|
| bypass | `prefetch_buffer` routed around entirely: the baseline Ara load path |
| off | `prefetch_buffer` in the path with `+pf_disable`: ROB only, no prefetching |
| on | prefetching enabled |

```bash
cd hardware
make verilate_unit veril_unit_top=pf_system_tb veril_unit_library=build/verilator-pfsys
python3 tb/unit/pf_sweep.py ../docs/ece499-prefetcher/results/<name>.csv \
                            ../docs/ece499-prefetcher/results/<name>.md "<label>"
```

Every run is self-checking: each beat handed to the `vldu` model must carry
the data of the address its request asked for.

## What these numbers are not

They are not full-system measurements. Only `prefetch_buffer` is real RTL; its
neighbours are models written from reading `ara_sequencer.sv`, `addrgen.sv`
and `vldu.sv`. In particular `L`, the gap between loads and the instruction-ID
policy are inputs to the model, not things it measures. The assumptions are
listed at the top of `pf_system_tb.sv`. A run of real RVV code on the full
CVA6+Ara model is still needed to confirm them.

## Step 0: v1 as submitted (`step0_v1.*`)

- **Speedup is 1.00x in all 84 configurations.** v1 sends one prefetch per
  instruction, so at most one element per instruction hits.
- **The ROB costs nothing.** `off` and `bypass` are identical in every run.
- **The baseline is limited by the 4-deep request queue once `L` reaches 4.**
  With `L = 7` each element costs 2 cycles, with `L = 12` it costs 3.25, i.e.
  `(L + 1) / 4`. The baseline is one element per cycle only for small `L`.
- **One hit per instruction is absorbed.** In the queue-limited regime 15
  misses still need 4 batches of 4, the same as 16.
- **The predictor often does not see the instructions at all.** New-instruction
  detection relies on the instruction ID changing. When a load finishes before
  the next one is dispatched, the next one reuses the same ID and is missed.
  With a 40-cycle gap this happens in most configurations, and no prefetch is
  ever sent.

A prediction made before running this, that `vl = 1` would show a speedup
because coverage is 100%, was wrong: the hit rate is 97% there but the time
per instruction is set by how fast instructions are dispatched, not by `L`.

## Step 1: predictor sends a stream (`step1_stream.*`)

`pf_predictor` now offers up to `MaxDegree` (16) addresses per trusted
prediction: the next instruction's elements, one after another. Buffer and
FIFO depths are still 4.

- **First non-1.00x results**, but only for `vl = 4`: up to 1.23x at `L = 12`.
  Four prefetches fit in a 4-entry buffer.
- **For `vl >= 8` hits drop to zero while prefetches go up** (about 500 to 1000
  sent, 0 used at `L >= 7`). The buffer replaces entries round-robin, so a
  stream longer than 4 overwrites its own first entries before the real
  requests arrive. This is the capacity problem step 2 addresses.
- The predictor still misses instructions that reuse an ID (unchanged).

## Step 2: capacity (`step2_capacity.*`)

Data buffer 4 -> 32, predictive ARs in flight 4 -> 16, `MaxDegree` 16.

Depths were chosen from seven combinations (geometric-mean speedup over the
84 configurations):

| buffer | in flight | MaxDegree | geomean | max | prefetches not used |
|---:|---:|---:|---:|---:|---:|
| 4 | 4 | 16 | 1.005 | 1.23x | 93% |
| 16 | 8 | 8 | 1.083 | 1.97x | 4% |
| 32 | 8 | 16 | 1.123 | 2.12x | 3% |
| **32** | **16** | **16** | **1.135** | **2.73x** | **3%** |
| 32 | 32 | 16 | 1.135 | 2.73x | 3% |
| 64 | 16 | 32 | 1.180 | 2.97x | 2% |
| 64 | 32 | 32 | 1.180 | 2.97x | 2% |

- **34 of 84 configurations are now faster, none is slower.** Largest: `vl =
  16`, `L = 12`, 52 -> 19 cycles per instruction (2.73x).
- **Where the gain comes from.** Real requests are capped at 4 outstanding by
  `addrgen`'s queue, so the baseline costs `(L + 1) / 4` cycles per element.
  Predictive ARs do not go through that queue: up to 16 can be outstanding.
  With every element prefetched, an instruction takes `vl + 3` cycles
  regardless of `L`. The speedup therefore grows with `L` and is 1.00x when
  `L` is small enough that the queue never fills.
- **`vl > MaxDegree` still gains, less.** At `vl = 32` half the elements are
  covered (1.53x at `L = 12`); at `vl = 64` a quarter (1.21x). Buffer 64 /
  MaxDegree 32 would lift these at twice the storage.
- **Almost nothing is wasted.** 97% of prefetches are used.
- **Instruction detection is now the main limit.** The predictor misses
  instructions in 32 of 84 runs, more than before, because loads finish
  sooner and their IDs are reused sooner. Most `gap = 40` runs are still
  1.00x for this reason alone.

## Step 3: new-instruction detection (`step3_detect.*`)

The first full-system run (CVA6 + Ara on ecetesla, `apps/pf_stride`) showed
**no prefetch at all**: `new_insn=1` over 240 loads, `pred_ar=0`, identical
cycles with prefetching on and off. Ara's sequencer gives each instruction
the lowest free ID, so once a load retires the next load gets the same ID
back, and an ID-change detector never fires.

`pf_predictor` now also treats "a load request appears after a cycle without
one" as a new instruction. A `load_req_rise` counter was added to
`+pf_stats`, and `pf_predictor_tb` gained a reused-ID scenario (it fails with
the old detector).

In the model bench the predictor now notices all 64 instructions in all 84
configurations (before: 32 runs missed some). Speedups are unchanged
(geomean 1.136, 34/84 faster, max 2.73x): the configurations that were
missing instructions have a long gap between loads, so time per instruction
is set by dispatch, not by memory, and prefetching cannot shorten it.

The same full-system run also confirmed the model's main assumption: the
real load round trip is 7 cycles and at most 4 real requests are
outstanding, and each extra element costs about 2.2 cycles, close to the
model's `(L + 1) / 4 = 2`.

## Full system: CVA6 + Ara on Verilator (`full_system_*`)

`apps/pf_stride` on the complete CVA6 + Ara + prefetcher model, built and run
on ecetesla4 with `apps/pf_stride/run_full_system.sh`: 64 back-to-back
`vlse64` loads per vector length, 64-byte stride, every lane checked against
a scalar sum. Both runs end with `Core Test *** SUCCESS ***`.

**Before the detection fix** (`full_system_20261018_1708`): on and off
identical, `new_insn=1`, `pred_ar=0`. No prefetch was ever issued.

**After the detection fix** (`full_system_20261018_1715`, commit `a2b4615a`):

| vl | off (cycles) | on (cycles) | speedup |
|---:|---:|---:|---:|
| 4 | 1,437 | 1,192 | 1.21x |
| 8 | 2,151 | 1,537 | 1.40x |
| 16 | 3,369 | 2,198 | 1.53x |
| 32 | 5,615 | 4,691 | 1.20x |

- 256 loads, 256 detected (`new_insn = load_req_rise = 256`), 3 mispredicts
  (where the vector length changes between runs).
- 2,728 of 3,840 element reads hit the buffer (71%); 2,728 of 2,772
  prefetches were used (98%).
- `vl = 32` gains less because `MaxDegree` is 16: only half of each
  instruction is prefetched.
- Real round trip 7 cycles, at most 4 real requests outstanding, as in the
  model's `L = 7` case.

The model bench predicted 1.68x for `vl = 16, L = 7` with no gap between
loads; the benchmark has a vector add and loop overhead between loads, so a
somewhat lower full-system number is expected.
