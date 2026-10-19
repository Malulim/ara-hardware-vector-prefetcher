// Directed unit test for pf_predictor's prefetch stream.
//
// Self-checking: every scenario is an immediate assertion, $fatal on the
// first violation, a PASS line per scenario and $finish at the end.
//
// A monitor records every address the predictor gets accepted
// (predict_valid_o && predict_ready_i at a clock edge) into `got`. Each
// scenario drives a few instructions, then compares `got` with the exact
// list of addresses expected.

module pf_predictor_tb;

  localparam int unsigned MaxDegree = 4;

  typedef logic [63:0] addr_t;
  typedef logic [63:0] stride_t;
  typedef logic [2:0]  size_t;
  typedef logic [2:0]  id_t;
  typedef struct packed {
    id_t         id;
    logic [63:0] scalar_op;
    logic [15:0] vl;
  } pe_req_t;

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  pe_req_t pe_req       = '0;
  logic    pe_req_valid = 1'b0;
  stride_t byte_stride  = '0;
  logic    is_strided   = 1'b1;
  logic    ready        = 1'b1;

  logic  valid, valid_noclip, mispredict, mispredict_noclip;
  addr_t addr, addr_noclip;

  pf_predictor #(
    .pe_req_t(pe_req_t), .stride_t(stride_t), .addr_t(addr_t), .size_t(size_t), .id_t(id_t),
    .MaxDegree(MaxDegree), .ClipWhenLarge(1'b1)
  ) i_dut (
    .clk_i(clk), .rst_ni(rst_n),
    .pe_req_i(pe_req), .pe_req_valid_i(pe_req_valid), .prefetchable_i(1'b1),
    .byte_stride_i(byte_stride), .size_i(3'd3), .is_strided_i(is_strided),
    .predict_valid_o(valid), .predict_ready_i(ready), .predicted_addr_o(addr),
    .predicted_size_o(), .predicted_is_strided_o(), .mispredict_o(mispredict)
  );

  // Same stimulus, ClipWhenLarge = 0, for the "vl too large" scenario.
  pf_predictor #(
    .pe_req_t(pe_req_t), .stride_t(stride_t), .addr_t(addr_t), .size_t(size_t), .id_t(id_t),
    .MaxDegree(MaxDegree), .ClipWhenLarge(1'b0)
  ) i_dut_noclip (
    .clk_i(clk), .rst_ni(rst_n),
    .pe_req_i(pe_req), .pe_req_valid_i(pe_req_valid), .prefetchable_i(1'b1),
    .byte_stride_i(byte_stride), .size_i(3'd3), .is_strided_i(is_strided),
    .predict_valid_o(valid_noclip), .predict_ready_i(ready), .predicted_addr_o(addr_noclip),
    .predicted_size_o(), .predicted_is_strided_o(), .mispredict_o(mispredict_noclip)
  );

  addr_t got [$];
  addr_t got_noclip [$];
  int unsigned mispredicts;
  always @(posedge clk) begin
    if (rst_n) begin
      if (valid && ready)               got.push_back(addr);
      if (valid_noclip && ready)        got_noclip.push_back(addr_noclip);
      if (mispredict)                   mispredicts++;
    end
  end

  id_t next_id = '0;

  // Offer one instruction for `hold` cycles, then drop valid for one cycle.
  task automatic insn(input logic [63:0] base, input int unsigned vl,
                      input logic [63:0] stride, input int unsigned hold);
    @(negedge clk);
    pe_req       = '{id: next_id, scalar_op: base, vl: 16'(vl)};
    byte_stride  = stride;
    pe_req_valid = 1'b1;
    next_id      = next_id + 3'd1;
    repeat (hold) @(negedge clk);
    pe_req_valid = 1'b0;
  endtask

  task automatic reset_dut;
    @(negedge clk);
    rst_n = 1'b0;
    pe_req_valid = 1'b0;
    ready = 1'b1;
    is_strided = 1'b1;
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    got.delete();
    got_noclip.delete();
    mispredicts = 0;
  endtask

  task automatic expect_got(input string name, input addr_t exp [$]);
    if (got.size() != exp.size())
      $fatal(1, "%s: %0d addresses accepted, expected %0d", name, got.size(), exp.size());
    foreach (exp[i])
      if (got[i] != exp[i])
        $fatal(1, "%s: address %0d is %0d, expected %0d", name, i, got[i], exp[i]);
    $display("[PASS] %s", name);
  endtask

  initial begin
    // 1. Three continuing instructions, vl = 4, stride 8 (32 bytes each).
    //    First: nothing to compare against. Second: matches, so it fetches
    //    the third's four elements. Third: matches, fetches the fourth's.
    reset_dut();
    insn(100, 4, 8, 8);
    insn(132, 4, 8, 8);
    expect_got("step1a: second instruction streams the third's 4 elements", '{164, 172, 180, 188});
    insn(164, 4, 8, 8);
    expect_got("step1b: third instruction streams the fourth's 4 elements",
               '{164, 172, 180, 188, 196, 204, 212, 220});

    // 2. Backpressure: with ready low the offered address must not move.
    reset_dut();
    insn(100, 4, 8, 2);
    @(negedge clk); ready = 1'b0;
    insn(132, 4, 8, 2);
    repeat (5) begin
      @(negedge clk);
      assert (valid && addr == 164) else $fatal(1, "step2: address moved or valid dropped while ready was low");
    end
    assert (got.size() == 0) else $fatal(1, "step2: something was accepted while ready was low");
    ready = 1'b1;
    repeat (6) @(negedge clk);
    expect_got("step2: stream holds under backpressure, then completes", '{164, 172, 180, 188});

    // 3. A new instruction arrives mid-stream: the old stream is dropped
    //    and replaced, not finished.
    reset_dut();
    insn(100, 4, 8, 2);
    @(negedge clk); ready = 1'b0;
    insn(132, 4, 8, 2);
    @(negedge clk); ready = 1'b1;       // let two of the four go
    repeat (2) @(negedge clk);
    ready = 1'b0;
    insn(164, 4, 8, 2);                 // matches; new stream starts at 196
    @(negedge clk); ready = 1'b1;
    repeat (6) @(negedge clk);
    expect_got("step3: new instruction replaces an unfinished stream",
               '{164, 172, 196, 204, 212, 220});

    // 3b. Same, but the new instruction arrives in the very cycle an
    //     address is being accepted. That address still counts (the
    //     handshake completed), and the stream is replaced right after.
    reset_dut();
    insn(100, 4, 8, 2);
    insn(132, 4, 8, 2);                 // stream 164.. starts, ready stays high
    insn(164, 4, 8, 8);                 // lands while 180 is being accepted
    expect_got("step3b: new instruction in the same cycle as an accepted address",
               '{164, 172, 180, 196, 204, 212, 220});

    // 4. Base address does not continue: mispredict, and nothing is sent.
    reset_dut();
    insn(100, 4, 8, 4);
    insn(900, 4, 8, 8);
    assert (mispredicts == 1) else $fatal(1, "step4: expected exactly one mispredict, saw %0d", mispredicts);
    expect_got("step4: a mispredicted instruction sends nothing", '{});

    // 5. vl larger than MaxDegree (4). Clip = 1 sends the first 4,
    //    Clip = 0 sends none.
    reset_dut();
    insn(100, 10, 8, 4);
    insn(180, 10, 8, 10);
    expect_got("step5a: vl > MaxDegree, clipped to MaxDegree", '{260, 268, 276, 284});
    assert (got_noclip.size() == 0) else $fatal(1, "step5b: ClipWhenLarge=0 still sent %0d addresses", got_noclip.size());
    $display("[PASS] step5b: vl > MaxDegree with ClipWhenLarge=0 sends nothing");

    // 6. Unit-stride (not strided): confidence still builds, nothing sent.
    reset_dut();
    is_strided = 1'b0;
    insn(100, 4, 8, 4);
    insn(132, 4, 8, 8);
    expect_got("step6: non-strided instructions send nothing", '{});

    // 8. Same id reused by the next load (what Ara's sequencer does once a
    //    load has retired): it must still count as a new instruction, as
    //    long as the request was withdrawn in between.
    reset_dut();
    insn(100, 4, 8, 4);
    next_id = next_id - 3'd1;          // reuse the previous id
    insn(132, 4, 8, 4);
    next_id = next_id - 3'd1;          // and again
    insn(164, 4, 8, 8);
    expect_got("step8: a reused id after valid drops is still a new instruction",
               '{164, 172, 180, 188, 196, 204, 212, 220});

    // 7. vl = 0: nothing to fetch.
    reset_dut();
    insn(100, 0, 8, 4);
    insn(100, 0, 8, 8);
    expect_got("step7: vl = 0 sends nothing", '{});

    $display("[PASS] all pf_predictor_tb checks passed");
    $finish;
  end

endmodule : pf_predictor_tb
