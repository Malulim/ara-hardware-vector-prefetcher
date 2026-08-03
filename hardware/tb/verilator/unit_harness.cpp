#include <cstdlib>
#include <cstdint>

#include "verilated.h"

#if defined(TRACE_VCD)
#include "verilated_vcd_c.h"
#endif

#ifndef TOP_HEADER
#error "TOP_HEADER must be defined, e.g. -DTOP_HEADER='\"Vunit_smoke_tb.h\"'"
#endif
#ifndef TOP_CLASS
#error "TOP_CLASS must be defined, e.g. -DTOP_CLASS=Vunit_smoke_tb"
#endif

#include TOP_HEADER

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  TOP_CLASS* top = new TOP_CLASS;

#if defined(TRACE_VCD)
  VerilatedVcdC* trace = new VerilatedVcdC;
  Verilated::traceEverOn(true);
  top->trace(trace, 99);
  trace->open("unit.vcd");
#endif

  while (!Verilated::gotFinish()) {
    top->eval();
    main_time++;
#if defined(TRACE_VCD)
    trace->dump(main_time);
#endif
  }

#if defined(TRACE_VCD)
  trace->close();
  delete trace;
#endif

  top->final();
  delete top;

  return EXIT_SUCCESS;
}
