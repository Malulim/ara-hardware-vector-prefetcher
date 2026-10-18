#!/usr/bin/env bash
# Full-system on/off comparison for the prefetcher. Run from the repo root on
# a machine that has the RISC-V LLVM toolchain installed for Ara (install/).
#
#   ./apps/pf_stride/run_full_system.sh
#
# Builds the microbenchmark, verilates CVA6 + Ara + prefetcher, runs the ELF
# with prefetching off and on, and prints the cycle counts and counters.
set -euo pipefail
cd "$(dirname "$0")/../.."

make -C apps bin/pf_stride
make -C hardware verilate

SIM=hardware/build/verilator/Vara_tb_verilator
ELF=apps/bin/pf_stride
OUT=docs/ece499-prefetcher/results/full_system_$(date +%Y%m%d_%H%M)
mkdir -p "$OUT"

"$SIM" -l "ram,$ELF,elf" +pf_stats +pf_disable | tee "$OUT/off.log"
"$SIM" -l "ram,$ELF,elf" +pf_stats              | tee "$OUT/on.log"

echo
echo "== off"; grep -E 'pf_stride:|PF_STATS' "$OUT/off.log"
echo "== on";  grep -E 'pf_stride:|PF_STATS' "$OUT/on.log"
echo "logs in $OUT"
