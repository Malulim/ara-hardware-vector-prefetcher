// Strided-load microbenchmark for the vector prefetcher (ECE 499 v2).
//
// Runs NINSN back-to-back vlse64 loads over one array, each continuing where
// the previous one ended (the pattern the predictor targets), for several
// vector lengths. Prints cycles per run. Run the same ELF twice on the
// Verilator model, with and without +pf_disable, and compare; add +pf_stats
// to get the prefetcher's counters.
//
// Self-checking: every lane's accumulated sum is compared with a scalar sum.

#include <stdint.h>

#include "runtime.h"
#include "util.h"

#ifndef SPIKE
#include "printf.h"
#else
#include <stdio.h>
#endif

#define NINSN     64
#define STRIDE_EL 8   // stride in elements: 64 bytes for int64
#define MAX_VL    32

static int64_t src[NINSN * MAX_VL * STRIDE_EL] __attribute__((aligned(64)));
static int64_t res[MAX_VL] __attribute__((aligned(64)));

static int64_t run(uint64_t avl) {
  uint64_t vl;
  const int64_t *p = src;
  const uint64_t stride = STRIDE_EL * sizeof(int64_t);
  asm volatile("vsetvli %0, %1, e64, m1, ta, ma" : "=r"(vl) : "r"(avl));
  asm volatile("vmv.v.i v16, 0");
  start_timer();
  for (int k = 0; k < NINSN; k++) {
    asm volatile("vlse64.v v8, (%0), %1" ::"r"(p), "r"(stride) : "memory");
    asm volatile("vadd.vv v16, v16, v8");
    p += vl * STRIDE_EL;
  }
  asm volatile("vse64.v v16, (%0)" ::"r"(res) : "memory");
  stop_timer();
  return get_timer();
}

int main() {
  const uint64_t avls[] = {4, 8, 16, 32};

  for (int i = 0; i < NINSN * MAX_VL * STRIDE_EL; i++)
    src[i] = 3 * (int64_t)i + 1;

  for (int t = 0; t < 4; t++) {
    uint64_t vl;
    asm volatile("vsetvli %0, %1, e64, m1, ta, ma" : "=r"(vl) : "r"(avls[t]));
    int64_t cycles = run(avls[t]);

    for (uint64_t j = 0; j < vl; j++) {
      int64_t gold = 0;
      for (int k = 0; k < NINSN; k++)
        gold += src[(k * vl + j) * STRIDE_EL];
      if (gold != res[j]) {
        printf("pf_stride: ERROR vl=%lu lane=%lu got=%ld expected=%ld\n", vl, j, res[j], gold);
        return -1;
      }
    }
    printf("pf_stride: vl=%lu stride_bytes=%d ninsn=%d cycles=%ld\n", vl, STRIDE_EL * 8, NINSN, cycles);
  }
  return 0;
}
