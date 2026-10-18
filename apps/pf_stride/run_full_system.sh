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

# The LLVM in install/ has no sysroot configured, so point it at the RISC-V
# GCC install for libc headers. On ecetesla, install/riscv-llvm's ld.lld also
# needs libxml2.so.2, which the OS no longer ships: set PF_LIB_COMPAT to a
# directory holding a libxml2.so.2 symlink to the system libxml2.so.16.
G="$PWD/install/riscv-gcc"
if [ -n "${PF_LIB_COMPAT:-}" ]; then
  export LD_LIBRARY_PATH="$PF_LIB_COMPAT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
make -C apps bin/pf_stride \
  LLVM_FLAGS="-march=rv64gcv_zfh_zvfh -mabi=lp64d -mno-relax -fuse-ld=lld --sysroot=$G/riscv64-unknown-elf --gcc-toolchain=$G"
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
