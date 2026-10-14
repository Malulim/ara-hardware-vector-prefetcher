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
