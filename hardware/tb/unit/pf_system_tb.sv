// System-level model testbench for the vector prefetcher.
//
// Wraps the real prefetch_buffer.sv (all seven pf_* modules, unmodified)
// in behavioural models of its three neighbours, so that the number of
// cycles a stream of strided loads takes can be compared with prefetching
// on, off, and with the whole block bypassed. No CVA6, no ELF, no RISC-V
// toolchain needed; a run takes milliseconds.
//
// What is real:    prefetch_buffer and everything inside it.
// What is a model: the instruction dispatcher, addrgen, vldu and memory.
// The models follow what the RTL does as read from ara_sequencer.sv,
// addrgen.sv and vldu.sv, but they are models. Numbers from this bench
// are "under these assumptions", not measurements of the full system.
//
// Model assumptions (each one is a knob or a constant below):
//   - Every instruction is a VLSE over one array, each continuing where
//     the previous one ended (the pattern the predictor is built for).
//   - addrgen issues one single-beat AR per element, one per cycle, and
//     may have at most MetaDepth (4, VaddrgenInsnQueueDepth) requests
//     whose data vldu has not consumed yet.
//   - vldu takes one beat per cycle whenever one is offered, and pairs it
//     with the oldest outstanding request purely by order.
//   - Memory answers every AR after LAT cycles, in the order accepted.
//   - The sequencer gives a new instruction the lowest free ID; an ID is
//     freed when the instruction's last element has been delivered.
//   - A new instruction appears GAP cycles after the previous one was
//     accepted by addrgen, and stays valid until addrgen is free.
//
// Self-checking: every beat handed to the vldu model must carry the data
// of the address that request asked for. A wrong order or a stale hit is
// a $fatal, in every run.
//
// Knobs (plusargs): +VL= +LAT= +GAP= +NINSN= +STRIDE= +START= +IDMODE=
//                   +BYPASS  (route around prefetch_buffer entirely)
//                   +pf_disable (inside the DUT: no predictive ARs)
//                   +pf_stats   (inside the DUT: print counters)

module pf_system_tb;

  localparam int unsigned AxiAddrWidth = 64;
  localparam int unsigned AxiDataWidth = 128;
  localparam int unsigned MetaDepth    = 4;   // ara_pkg::VaddrgenInsnQueueDepth
  localparam int unsigned NrIds        = 8;   // ara_pkg::NrVInsn
  localparam int unsigned MemDepth     = 256;

  typedef logic [AxiAddrWidth-1:0] addr_t;
  typedef logic [AxiDataWidth-1:0] data_t;

  typedef struct packed {
    logic [3:0]       id;
    addr_t            addr;
    axi_pkg::len_t    len;
    axi_pkg::size_t   size;
    axi_pkg::burst_t  burst;
    axi_pkg::cache_t  cache;
  } ar_t;

  typedef struct packed {
    logic [3:0]      id;
    data_t           data;
    axi_pkg::resp_t  resp;
    logic            last;
  } r_t;

  // Only the fields pf_classifier and pf_predictor read.
  typedef struct packed {
    logic [2:0] vsew;
  } vtype_t;
  typedef struct packed {
    ara_pkg::ara_op_e op;
    vtype_t           vtype;
    logic [63:0]      stride;
    logic [2:0]       id;
    logic [63:0]      scalar_op;
    logic [15:0]      vl;
  } pe_req_t;

  // -------------------------------------------------------------------
  // Knobs
  // -------------------------------------------------------------------
  int unsigned VL, LAT, GAP, NINSN, STRIDE, START, IDMODE;
  logic        bypass;
  initial begin
    if (!$value$plusargs("VL=%d",     VL))     VL     = 16;
    if (!$value$plusargs("LAT=%d",    LAT))    LAT    = 4;
    if (!$value$plusargs("GAP=%d",    GAP))    GAP    = 0;
    if (!$value$plusargs("NINSN=%d",  NINSN))  NINSN  = 64;
    if (!$value$plusargs("STRIDE=%d", STRIDE)) STRIDE = 16;
    if (!$value$plusargs("START=%d",  START))  START  = 2;
    if (!$value$plusargs("IDMODE=%d", IDMODE)) IDMODE = 0;
    bypass = $test$plusargs("BYPASS");
  end

  localparam addr_t Base = 64'h0000_0000_8000_0000;

  function automatic data_t mem_data(addr_t a);
    return {~a, a} ^ 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;
  endfunction

  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;
  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
  end

  longint unsigned cyc;

  // -------------------------------------------------------------------
  // Wires around the DUT
  // -------------------------------------------------------------------
  pe_req_t pe_req;
  logic    pe_req_valid;

  ar_t  ag_ar;                         // addrgen model -> (DUT | memory)
  logic ag_ar_valid, ag_ar_ready;
  ar_t  dut_ar;                        // DUT -> memory
  logic dut_ar_valid, dut_ar_ready;
  r_t   dut_r;                         // DUT -> vldu model
  logic dut_r_valid, dut_r_ready;

  ar_t  mem_ar;
  logic mem_ar_valid, mem_ar_ready;
  r_t   mem_r;
  logic mem_r_valid, mem_r_ready;

  r_t   vl_r;                          // what the vldu model sees
  logic vl_r_valid, vl_r_ready;

  prefetch_buffer #(
    .AxiAddrWidth(AxiAddrWidth   ),
    .AxiDataWidth(AxiDataWidth   ),
    .axi_ar_t    (ar_t           ),
    .axi_r_t     (r_t            ),
    .pe_req_t    (pe_req_t       ),
    .stride_t    (logic [63:0]   ),
    .size_t      (axi_pkg::size_t),
    .id_t        (logic [2:0]    )
  ) i_dut (
    .clk_i             (clk                        ),
    .rst_ni            (rst_n                      ),
    .pe_req_i          (pe_req                     ),
    .pe_req_valid_i    (pe_req_valid && !bypass    ),
    .axi_ar_i          (ag_ar                      ),
    .axi_ar_valid_i    (ag_ar_valid && !bypass     ),
    .axi_ar_ready_o    (dut_ar_ready               ),
    .axi_ar_o          (dut_ar                     ),
    .axi_ar_valid_o    (dut_ar_valid               ),
    .axi_ar_ready_i    (mem_ar_ready && !bypass    ),
    .axi_r_i           (mem_r                      ),
    .axi_r_valid_i     (mem_r_valid && !bypass     ),
    .axi_r_ready_o     (dut_r_ready                ),
    .axi_r_o           (dut_r                      ),
    .axi_r_valid_o     (dut_r_valid                ),
    .axi_r_ready_i     (vl_r_ready && !bypass      ),
    .cva6_inval_valid_i(1'b0                       ),
    .cva6_inval_addr_i ('0                         ),
    .cva6_inval_len_i  ('0                         ),
    .cva6_inval_size_i ('0                         )
  );

  assign ag_ar_ready  = bypass ? mem_ar_ready : dut_ar_ready;
  assign mem_ar       = bypass ? ag_ar        : dut_ar;
  assign mem_ar_valid = bypass ? ag_ar_valid  : dut_ar_valid;
  assign mem_r_ready  = bypass ? vl_r_ready   : dut_r_ready;
  assign vl_r         = bypass ? mem_r        : dut_r;
  assign vl_r_valid   = bypass ? mem_r_valid  : dut_r_valid;

  // -------------------------------------------------------------------
  // Dispatcher + addrgen + vldu models
  // -------------------------------------------------------------------
  // Dispatcher: the instruction currently offered on pe_req.
  logic              disp_valid;
  int unsigned       disp_k, next_k, disp_timer;
  logic [2:0]        disp_id, rr_id;
  logic [NrIds-1:0]  running;

  // addrgen: the instruction whose ARs are being issued.
  logic        ag_busy;
  int unsigned ag_i, ag_start_cnt;
  addr_t       ag_base;
  logic [2:0]  ag_id;

  // Side queue addrgen -> vldu: one entry per issued AR.
  addr_t      meta_addr [MetaDepth];
  logic       meta_last [MetaDepth];
  logic [2:0] meta_id   [MetaDepth];
  int unsigned meta_w, meta_r, meta_cnt;

  int unsigned     done;
  longint unsigned t_first, t_half;
  logic            t_first_set;

  logic ack, ag_ar_fire, vl_r_fire;
  assign ack        = disp_valid && !ag_busy;
  assign ag_ar_fire = ag_ar_valid && ag_ar_ready;
  assign vl_r_ready = (meta_cnt != 0);
  assign vl_r_fire  = vl_r_valid && vl_r_ready;

  assign pe_req_valid = disp_valid;
  assign pe_req = '{
    op       : ara_pkg::VLSE,
    vtype    : '{vsew: 3'd3},
    stride   : 64'(STRIDE),
    id       : disp_id,
    scalar_op: Base + 64'(disp_k) * 64'(VL) * 64'(STRIDE),
    vl       : 16'(VL)
  };

  assign ag_ar_valid = ag_busy && (ag_start_cnt == 0) && (ag_i < VL) && (meta_cnt < MetaDepth);
  assign ag_ar = '{
    id     : '0,
    addr   : ag_base + 64'(ag_i) * 64'(STRIDE),
    len    : '0,
    size   : 3'd3,
    burst  : axi_pkg::BURST_INCR,
    cache  : '0
  };

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc          <= '0;
      disp_valid   <= 1'b0;
      disp_k       <= 0;
      next_k       <= 0;
      disp_timer   <= 0;
      disp_id      <= '0;
      rr_id        <= '0;
      running      <= '0;
      ag_busy      <= 1'b0;
      ag_i         <= 0;
      ag_start_cnt <= 0;
      ag_base      <= '0;
      ag_id        <= '0;
      meta_w       <= 0;
      meta_r       <= 0;
      meta_cnt     <= 0;
      done         <= 0;
      t_first      <= '0;
      t_half       <= '0;
      t_first_set  <= 1'b0;
    end else begin
      automatic logic [NrIds-1:0] run_n = running;
      cyc <= cyc + 1;

      // --- vldu: consume one beat, check it, free the ID on the last one.
      if (vl_r_fire) begin
        if (vl_r.data !== mem_data(meta_addr[meta_r]))
          $fatal(1, "pf_system_tb: beat for addr %h carried the wrong data (cycle %0d)",
                 meta_addr[meta_r], cyc);
        if (meta_last[meta_r]) begin
          run_n[meta_id[meta_r]] = 1'b0;
          done <= done + 1;
          if (done + 1 == NINSN / 2) t_half <= cyc;
        end
        meta_r <= (meta_r + 1) % MetaDepth;
      end

      // --- addrgen: issue ARs for the accepted instruction.
      if (ag_busy) begin
        if (ag_start_cnt != 0) begin
          ag_start_cnt <= ag_start_cnt - 1;
        end else if (ag_ar_fire) begin
          meta_addr[meta_w] <= ag_ar.addr;
          meta_last[meta_w] <= (ag_i + 1 == VL);
          meta_id  [meta_w] <= ag_id;
          meta_w            <= (meta_w + 1) % MetaDepth;
          ag_i              <= ag_i + 1;
          if (ag_i + 1 == VL) ag_busy <= 1'b0;
        end
      end
      case ({ag_ar_fire, vl_r_fire})
        2'b10:   meta_cnt <= meta_cnt + 1;
        2'b01:   meta_cnt <= meta_cnt - 1;
        default: ;
      endcase

      // --- dispatcher: offer the next instruction, hand it to addrgen.
      if (ack) begin
        disp_valid   <= 1'b0;
        next_k       <= next_k + 1;
        disp_timer   <= GAP;
        ag_busy      <= 1'b1;
        ag_i         <= 0;
        ag_start_cnt <= START;
        ag_base      <= pe_req.scalar_op;
        ag_id        <= disp_id;
      end else if (!disp_valid && next_k < NINSN) begin
        if (disp_timer != 0) begin
          disp_timer <= disp_timer - 1;
        end else begin
          automatic logic       found = 1'b0;
          automatic logic [2:0] pick  = '0;
          if (IDMODE == 1) begin
            // Sensitivity option: a fresh ID every time, round robin.
            found = 1'b1;
            pick  = rr_id;
          end else begin
            for (int i = NrIds - 1; i >= 0; i--)
              if (!run_n[i]) begin
                found = 1'b1;
                pick  = 3'(i);
              end
          end
          if (found) begin
            disp_valid  <= 1'b1;
            disp_k      <= next_k;
            disp_id     <= pick;
            rr_id       <= rr_id + 3'd1;
            run_n[pick]  = 1'b1;
            if (!t_first_set) begin
              t_first     <= cyc;
              t_first_set <= 1'b1;
            end
          end
        end
      end

      running <= run_n;

      if (cyc > 64'd5_000_000) $fatal(1, "pf_system_tb: timeout");
    end
  end

  // -------------------------------------------------------------------
  // Memory model: accept every AR, answer LAT cycles later, in order.
  // -------------------------------------------------------------------
  logic [3:0]      m_id   [MemDepth];
  addr_t           m_addr [MemDepth];
  longint unsigned m_t    [MemDepth];
  logic [7:0]      m_w, m_r;
  int unsigned     m_cnt;

  assign mem_ar_ready = (m_cnt < MemDepth - 1);
  assign mem_r_valid  = (m_cnt != 0) && (cyc >= m_t[m_r]);
  assign mem_r = '{
    id  : m_id[m_r],
    data: mem_data(m_addr[m_r]),
    resp: axi_pkg::RESP_OKAY,
    last: 1'b1
  };

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_w   <= '0;
      m_r   <= '0;
      m_cnt <= 0;
    end else begin
      if (mem_ar_valid && mem_ar_ready) begin
        m_id  [m_w] <= mem_ar.id;
        m_addr[m_w] <= mem_ar.addr;
        m_t   [m_w] <= cyc + 64'(LAT);
        m_w         <= m_w + 8'd1;
      end
      if (mem_r_valid && mem_r_ready) m_r <= m_r + 8'd1;
      case ({mem_ar_valid && mem_ar_ready, mem_r_valid && mem_r_ready})
        2'b10:   m_cnt <= m_cnt + 1;
        2'b01:   m_cnt <= m_cnt - 1;
        default: ;
      endcase
    end
  end

  // -------------------------------------------------------------------
  // Finish
  // -------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && done == NINSN && NINSN != 0) begin
      // steady_x100: average cycles per instruction over the second half
      // of the run, times 100, so the warm-up does not blur the number.
      $display("PF_RESULT vl=%0d lat=%0d gap=%0d ninsn=%0d bypass=%0d idmode=%0d cycles=%0d steady_x100=%0d",
               VL, LAT, GAP, NINSN, bypass, IDMODE, cyc - t_first,
               ((cyc - t_half) * 100) / (NINSN - NINSN / 2));
      $finish;
    end
  end

endmodule : pf_system_tb
