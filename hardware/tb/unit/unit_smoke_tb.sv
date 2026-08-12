// Directed smoke test for pf_rob.sv + pf_data_buffer.sv wired together --
// the two modules responsible for the prefetcher's one correctness-
// critical property: real ARs are released to vldu strictly in the order
// they were issued, regardless of whether each one was resolved by a
// buffer hit (instant) or a real R (arbitrarily delayed). See pf_rob.sv's
// header comment for the property; this test exercises it directly rather
// than trusting the by-hand argument.
//
// Deliberately does not pull in ara_pkg/axi_pkg or any other ARA type --
// pf_rob/pf_data_buffer's ports are all `parameter type`, so a minimal
// local ar_t/r_t is enough to drive them standalone. classifier/predictor/
// throttle/r_router/addr_fifo are not exercised here (each is either pure
// combinational or a thin wrapper around a proven common_cells FIFO; the
// ROB+buffer pair is where an actual bug would hide).
//
// Also exercises both halves of the coherency mechanism. step5 drives
// pf_data_buffer.sv's inval_* port: a simulated CVA6 store overlapping a
// cached entry's address must clear it, so a subsequent real AR to that
// address misses instead of hitting stale data. step6 drives
// pf_addr_fifo.sv (instantiated standalone -- no predictive AR path
// exists in this TB to reach it through) for the mirror-image case, where
// the store lands while the fetch is still in flight and no buffer entry
// exists yet to clear.
//
// Combinational outputs (ar_valid_o, r_valid_o, ...) are only ever
// inspected at @(negedge clk), never in the same statement flow as the
// input change that drives them: pf_rob's always_ff is sensitive only to
// `posedge clk_i or negedge rst_ni`, so negedge clk is a point where it is
// provably quiescent -- reading combinational outputs there can never race
// against an in-flight register commit the way reading immediately after
// a blocking input assignment can.
//
// Self-checking: every step is an immediate assertion, `$fatal` on the
// first violation, `$finish` with a PASS line if the whole sequence
// completes. No framework, no scoreboard -- see unit_harness.cpp, which
// just runs until $finish/$fatal.

module unit_smoke_tb;

  localparam int unsigned Depth = 4;

  typedef logic [15:0] addr_t;
  typedef logic [2:0]  size_t;
  typedef struct packed {
    addr_t addr;
    logic [7:0] len;
    size_t size;
  } ar_t;
  typedef struct packed {
    logic [31:0] data;
  } r_t;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------
  // DUT: pf_data_buffer <-> pf_rob, wired exactly as prefetch_buffer.sv
  // wires them (lookup/fill interface).
  // ---------------------------------------------------------------------
  logic          lookup_valid;
  addr_t         lookup_addr;
  size_t         lookup_size;
  pf_pkg::pf_entry_state_e lookup_state;
  r_t            lookup_data;

  logic  fill_valid;
  addr_t fill_addr;
  size_t fill_size;
  r_t    fill_data;

  logic          inval_valid;
  addr_t         inval_addr;
  axi_pkg::len_t inval_len;
  size_t         inval_size;

  pf_data_buffer #(
    .Depth (Depth),
    .addr_t(addr_t),
    .size_t(size_t),
    .data_t(r_t   )
  ) i_data_buffer (
    .clk_i         (clk         ),
    .rst_ni        (rst_n       ),
    .flush_i       (1'b0        ),
    .lookup_valid_i(lookup_valid),
    .lookup_addr_i (lookup_addr ),
    .lookup_size_i (lookup_size ),
    .lookup_state_o(lookup_state),
    .lookup_data_o (lookup_data ),
    .fill_valid_i  (fill_valid  ),
    .fill_addr_i   (fill_addr   ),
    .fill_size_i   (fill_size   ),
    .fill_data_i   (fill_data   ),
    .inval_valid_i (inval_valid ),
    .inval_addr_i  (inval_addr  ),
    .inval_len_i   (inval_len   ),
    .inval_size_i  (inval_size  )
  );

  // pf_addr_fifo, instantiated standalone (step6). Not wired to the
  // pf_rob/pf_data_buffer pair above -- this TB has no predictive AR path
  // to drive it end-to-end, but its two properties (pop order equals push
  // order; an inval poisons exactly the overlapping entry and that flag
  // survives to the pop) are checkable in isolation, and the second is the
  // half of the coherency mechanism step5 does not reach.
  logic          af_push_valid, af_full;
  addr_t         af_push_addr;
  size_t         af_push_size;
  logic          af_pop, af_pop_poisoned, af_empty;
  addr_t         af_pop_addr;
  size_t         af_pop_size;
  logic          af_inval_valid;
  addr_t         af_inval_addr;
  axi_pkg::len_t af_inval_len;
  size_t         af_inval_size;

  pf_addr_fifo #(
    .Depth (Depth),
    .addr_t(addr_t),
    .size_t(size_t)
  ) i_addr_fifo (
    .clk_i         (clk            ),
    .rst_ni        (rst_n          ),
    .push_valid_i  (af_push_valid  ),
    .push_addr_i   (af_push_addr   ),
    .push_size_i   (af_push_size   ),
    .full_o        (af_full        ),
    .pop_i         (af_pop         ),
    .pop_addr_o    (af_pop_addr    ),
    .pop_size_o    (af_pop_size    ),
    .pop_poisoned_o(af_pop_poisoned),
    .empty_o       (af_empty       ),
    .inval_valid_i (af_inval_valid ),
    .inval_addr_i  (af_inval_addr  ),
    .inval_len_i   (af_inval_len   ),
    .inval_size_i  (af_inval_size  )
  );

  ar_t   ar_i;
  logic  ar_valid_i, ar_ready_o;
  ar_t   ar_o;
  logic  ar_valid_o, ar_ready_i;
  r_t    r_i;
  logic  r_valid_i, r_ready_o;
  r_t    r_o;
  logic  r_valid_o, r_ready_i;

  pf_rob #(
    .Depth   (Depth),
    .axi_ar_t(ar_t ),
    .axi_r_t (r_t  ),
    .addr_t  (addr_t),
    .size_t  (size_t)
  ) i_rob (
    .clk_i                (clk         ),
    .rst_ni               (rst_n       ),
    .flush_i              (1'b0        ),
    .axi_ar_i             (ar_i        ),
    .axi_ar_valid_i       (ar_valid_i  ),
    .axi_ar_ready_o       (ar_ready_o  ),
    .pred_ar_i             ('0         ),
    .pred_ar_valid_i       (1'b0       ),
    .pred_ar_ready_o       (           ),
    .pred_ar_fire_o        (           ),
    .pred_addr_fifo_full_i (1'b0       ),
    .axi_ar_o             (ar_o        ),
    .axi_ar_valid_o       (ar_valid_o  ),
    .axi_ar_ready_i       (ar_ready_i  ),
    .axi_r_i              (r_i         ),
    .axi_r_valid_i        (r_valid_i   ),
    .axi_r_ready_o        (r_ready_o   ),
    .axi_r_o              (r_o         ),
    .axi_r_valid_o        (r_valid_o   ),
    .axi_r_ready_i        (r_ready_i   ),
    .lookup_valid_o       (lookup_valid),
    .lookup_addr_o        (lookup_addr ),
    .lookup_size_o        (lookup_size ),
    .lookup_state_i       (lookup_state),
    .lookup_data_i        (lookup_data )
  );

  // Testbench stands in for both "the real memory" (accepts ar_o, answers
  // r_i whenever the test drives it) and "vldu" (r_ready_i).
  assign ar_ready_i = 1'b1;
  assign r_ready_i  = 1'b1;

  // The #1 matters: without it, a blocking stimulus assignment made by the
  // caller immediately after this returns races pf_rob's/pf_data_buffer's
  // `always_ff @(posedge clk_i)` for the very edge just woken on -- same
  // simulation time, order between the two undefined. Landing 1 timeunit
  // past the edge guarantees every posedge always_ff has already latched
  // this cycle's stimulus before the next assignment can touch it.
  task automatic step;
    @(posedge clk);
    #1;
  endtask

  // Safe point to inspect combinational outputs -- see header comment.
  task automatic check_point;
    @(negedge clk);
  endtask

  task automatic seed_buffer(input addr_t addr, input size_t size, input r_t data);
    fill_addr  = addr;
    fill_size  = size;
    fill_data  = data;
    fill_valid = 1'b1;
    step();
    fill_valid = 1'b0;
  endtask

  initial begin
    ar_valid_i     = 1'b0;
    fill_valid     = 1'b0;
    r_valid_i      = 1'b0;
    inval_valid    = 1'b0;
    af_push_valid  = 1'b0;
    af_pop         = 1'b0;
    af_inval_valid = 1'b0;
    repeat (3) step();
    rst_n = 1'b1;
    repeat (2) step();

    // -------------------------------------------------------------------
    // Step 1: cold miss. Buffer is empty -> real AR must go out, and the
    // R that comes back must be forwarded through untouched.
    // -------------------------------------------------------------------
    ar_i       = '{addr: 16'h0100, len: 8'h00, size: 3'h2};
    ar_valid_i = 1'b1;
    check_point();
    assert (ar_valid_o) else $fatal(1, "step1: miss should have forwarded a real AR");
    assert (ar_o.addr == 16'h0100) else $fatal(1, "step1: forwarded AR has wrong addr");
    step();
    ar_valid_i = 1'b0;

    r_i       = '{data: 32'hAAAA_0001};
    r_valid_i = 1'b1;
    check_point();
    assert (r_valid_o && r_o.data == 32'hAAAA_0001)
      else $fatal(1, "step1: miss R was not forwarded correctly");
    step();
    r_valid_i = 1'b0;
    $display("[PASS] step1: cold miss forwards real AR and passes R through");

    // -------------------------------------------------------------------
    // Step 2 + 3: seed the buffer directly (standing in for a predictive
    // fill via pf_r_router, not under test here), then confirm a real AR
    // to that {addr,size} hits and releases without touching the real
    // AR/R channel at all.
    // -------------------------------------------------------------------
    seed_buffer(16'h0200, 3'h2, '{data: 32'hBBBB_0002});

    ar_i       = '{addr: 16'h0200, len: 8'h00, size: 3'h2};
    ar_valid_i = 1'b1;
    check_point();
    assert (!ar_valid_o) else $fatal(1, "step3: a hit must not touch the real AR channel");
    assert (ar_ready_o) else $fatal(1, "step3: a hit must be accepted with no backpressure");
    step();
    ar_valid_i = 1'b0;

    check_point();
    assert (r_valid_o && r_o.data == 32'hBBBB_0002)
      else $fatal(1, "step3: hit data did not release with the right value");
    step();
    $display("[PASS] step3: buffer hit releases immediately, no real AR/R traffic");

    // -------------------------------------------------------------------
    // Step 4: the property that actually matters. An older miss and a
    // younger hit are both outstanding at once -- the hit's data must NOT
    // jump ahead of the still-pending miss, even though it is ready first.
    // -------------------------------------------------------------------
    seed_buffer(16'h0400, 3'h2, '{data: 32'hCCCC_0004});

    ar_i       = '{addr: 16'h0500, len: 8'h00, size: 3'h2}; // older: miss
    ar_valid_i = 1'b1;
    check_point();
    assert (ar_valid_o && ar_o.addr == 16'h0500)
      else $fatal(1, "step4: older miss should have forwarded its real AR");
    step();

    ar_i = '{addr: 16'h0400, len: 8'h00, size: 3'h2}; // younger: hit, already buffered
    check_point();
    assert (!ar_valid_o) else $fatal(1, "step4: younger hit must not touch the real AR channel");
    step();
    ar_valid_i = 1'b0;

    // The younger hit's data is ready right now, but nothing may be
    // released yet -- the older miss is still at the head of the ROB.
    repeat (3) begin
      check_point();
      assert (!r_valid_o)
        else $fatal(1, "step4: hit data released before the older miss it queued behind");
      step();
    end

    // Now the older miss's real R finally arrives.
    r_i       = '{data: 32'hDDDD_0005};
    r_valid_i = 1'b1;
    check_point();
    assert (r_valid_o && r_o.data == 32'hDDDD_0005)
      else $fatal(1, "step4: older miss's data should release first");
    step();
    r_valid_i = 1'b0;

    // Only now should the younger hit's data follow, unprompted.
    check_point();
    assert (r_valid_o && r_o.data == 32'hCCCC_0004)
      else $fatal(1, "step4: younger hit's data should release immediately after, in order");
    step();
    $display("[PASS] step4: hit does not jump the queue ahead of an older outstanding miss");

    // -------------------------------------------------------------------
    // Step 5: coherency. Seed an entry, then simulate a CVA6 store landing
    // on it (pf_data_buffer.sv's inval_* port) -- a subsequent real AR to
    // the same {addr,size} must miss (touch the real AR channel) instead
    // of serving the now-stale cached data.
    // -------------------------------------------------------------------
    seed_buffer(16'h0600, 3'h2, '{data: 32'hEEEE_0006});

    inval_addr  = 16'h0600;
    inval_len   = 8'h00;
    inval_size  = 3'h2;
    inval_valid = 1'b1;
    step();
    inval_valid = 1'b0;

    ar_i       = '{addr: 16'h0600, len: 8'h00, size: 3'h2};
    ar_valid_i = 1'b1;
    check_point();
    assert (ar_valid_o && ar_o.addr == 16'h0600)
      else $fatal(1, "step5: post-invalidate AR should miss and forward a real AR");
    step();
    ar_valid_i = 1'b0;
    $display("[PASS] step5: store invalidation clears the cached entry, next AR misses");

    // -------------------------------------------------------------------
    // Step 6: pf_addr_fifo's half of the coherency mechanism. Two
    // predictive ARs are outstanding; a CVA6 store lands on the second
    // one's address while it is still in flight. The store must poison
    // exactly that entry -- not the first, not the whole FIFO -- and pop
    // order must stay push order so pf_r_router still pairs each returning
    // beat with the address that requested it.
    //
    // Also the regression guard for the flush bug: pf_addr_fifo has no
    // flush_i precisely because a mispredict cannot un-issue an AR already
    // on the bus. Re-adding one that resets the pointers would leave a
    // returning beat popping a stale {addr, size} and filling the data
    // buffer under the wrong key -- data corruption a later real load
    // would consume as its own.
    // -------------------------------------------------------------------
    af_push_addr  = 16'h0700;
    af_push_size  = 3'h2;
    af_push_valid = 1'b1;
    step();
    af_push_addr = 16'h0800;
    step();
    af_push_valid = 1'b0;

    af_inval_addr  = 16'h0800;
    af_inval_len   = 8'h00;
    af_inval_size  = 3'h2;
    af_inval_valid = 1'b1;
    step();
    af_inval_valid = 1'b0;

    check_point();
    assert (af_pop_addr == 16'h0700 && !af_pop_poisoned)
      else $fatal(1, "step6: head must still be the older, un-stored-to entry, unpoisoned");
    af_pop = 1'b1;
    step();
    af_pop = 1'b0;

    check_point();
    assert (af_pop_addr == 16'h0800 && af_pop_poisoned)
      else $fatal(1, "step6: the stored-to in-flight entry must pop next, marked poisoned");
    af_pop = 1'b1;
    step();
    af_pop = 1'b0;

    check_point();
    assert (af_empty) else $fatal(1, "step6: FIFO should be empty after both pops");
    $display("[PASS] step6: store poisons only the in-flight entry it overlaps, pop order kept");

    $display("[PASS] all unit_smoke_tb checks passed");
    $finish;
  end

endmodule
