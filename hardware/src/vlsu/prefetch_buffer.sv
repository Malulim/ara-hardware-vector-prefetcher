// Sits on Ara's AR/R load path, between the address generator and the AXI
// cut. Pure module-to-module wiring, no decision logic of its own -- the
// actual behavior lives in pf_classifier.sv, pf_predictor.sv,
// pf_addr_fifo.sv, pf_rob.sv, pf_r_router.sv and pf_data_buffer.sv.
//
// classifier + predictor run for every VLE/VLSE instruction observed on
// pe_req_i, which is wired in separately from (not derived from) the AR/R
// traffic below -- stride/EEW/vl live only in the instruction, never on
// the AXI channels. predictor's confidence FSM decides *whether* a given
// instruction's prediction is trusted enough to offer downstream at all,
// and additionally only lets strided (VLSE) predictions become real
// predictive ARs -- VLE still builds confidence-FSM state for
// future reference but never reaches the AXI bus. A hit is
// only ever recognized for a single-beat (len=0) request whose {addr,
// size} both match a cached entry, since the buffer caches one beat per
// entry. A predictive (id=1) completion is only cached if its r_resp is
// RESP_OKAY.

module prefetch_buffer import pf_pkg::*; import axi_pkg::*; #(
    parameter int  unsigned AxiAddrWidth = 0,
    parameter int  unsigned AxiDataWidth = 0,
    parameter type          axi_ar_t     = logic,
    parameter type          axi_r_t      = logic,
    parameter type          pe_req_t     = logic,
    parameter type          stride_t     = logic,
    parameter type          size_t       = logic,
    parameter type          id_t         = logic,
    // ROB depth: number of real ARs (hit or miss) that may be outstanding
    // at once. Matches VaddrgenInsnQueueDepth (ara_pkg.sv) so this stage
    // does not reduce Ara's existing outstanding-request capacity.
    parameter int  unsigned RobDepth          = 4,
    parameter int  unsigned DataBufDepth      = 4,
    // Depth of the side FIFO tracking addresses of outstanding predictive
    // ARs -- AXI's R channel never echoes back the request address.
    parameter int  unsigned PredAddrFifoDepth = 4,
    // Dependent parameters. DO NOT CHANGE!
    localparam type         addr_t       = logic [AxiAddrWidth-1:0]
  ) (
    input  logic    clk_i,
    input  logic    rst_ni,

    // Instruction stream, observed in parallel with the AR/R traffic below
    // (not derived from it -- see header comment).
    input  pe_req_t pe_req_i,
    input  logic    pe_req_valid_i,

    // AR: from addrgen
    input  axi_ar_t axi_ar_i,
    input  logic    axi_ar_valid_i,
    output logic    axi_ar_ready_o,

    // AR: to the AXI cut / memory
    output axi_ar_t axi_ar_o,
    output logic    axi_ar_valid_o,
    input  logic    axi_ar_ready_i,

    // R: from the AXI cut / memory
    input  axi_r_t  axi_r_i,
    input  logic    axi_r_valid_i,
    output logic    axi_r_ready_o,

    // R: to vldu
    output axi_r_t  axi_r_o,
    output logic    axi_r_valid_o,
    input  logic    axi_r_ready_i,

    // Coherency: CVA6's own AW stream (snooped pre-mux in ara_system.sv,
    // one pulse per accepted AW beat/burst -- see pf_data_buffer.sv and
    // pf_addr_fifo.sv's inval_* ports for what each side does with it).
    // The reverse direction of axi_inval_filter.sv (which watches ARA's
    // AW to invalidate CVA6's L1 DCache); nothing upstream of Ara's own
    // VLSU has an equivalent of CVA6's "stall issue while an accelerator
    // store is pending" trick, so both the resident-data buffer and the
    // in-flight address tracker need their own inval port -- see
    // pf_addr_fifo.sv's header comment for the race that leaves open if
    // only pf_data_buffer is covered.
    input  logic          cva6_inval_valid_i,
    input  addr_t         cva6_inval_addr_i,
    input  axi_pkg::len_t cva6_inval_len_i,
    input  size_t         cva6_inval_size_i
  );

  // Driven by predictor's mispredict_o below. Deliberately reaches only
  // pf_data_buffer -- not pf_rob (see the mispredict_o port comment in
  // pf_predictor.sv for why pf_rob must never be reset by a stride guess
  // going wrong) and not pf_addr_fifo (which tracks ARs physically
  // outstanding on the bus, and a mispredict does not un-issue them --
  // see pf_addr_fifo.sv's header for the corruption clearing it causes).
  logic flush;
  logic rob_flush;
  assign rob_flush = 1'b0;

  // Simulation-only kill switch for on/off comparisons: +pf_disable keeps
  // every predictive AR off the bus. The real path (ROB, in-order release)
  // is unchanged, so the comparison isolates the effect of prefetching.
  logic pf_disable;
`ifndef SYNTHESIS
  initial pf_disable = $test$plusargs("pf_disable");
`else
  assign pf_disable = 1'b0;
`endif

  // ---------------------------------------------------------------------
  // Classify + predict the next instruction's base address.
  // size_o/predicted_size_o/is_strided are forwarded end-to-end, never
  // re-derived.
  // ---------------------------------------------------------------------
  logic    prefetchable;
  stride_t byte_stride;
  size_t   classified_size;
  logic    is_strided;

  pf_classifier #(
    .pe_req_t(pe_req_t),
    .stride_t(stride_t),
    .size_t  (size_t  )
  ) i_pf_classifier (
    .pe_req_i      (pe_req_i       ),
    .prefetchable_o(prefetchable   ),
    .byte_stride_o (byte_stride    ),
    .size_o        (classified_size),
    .is_strided_o  (is_strided     )
  );

  logic  predict_valid, predict_ready;
  addr_t predicted_addr;
  size_t predicted_size;
  logic  predicted_is_strided;
  logic  mispredict;

  pf_predictor #(
    .pe_req_t(pe_req_t),
    .stride_t(stride_t),
    .addr_t  (addr_t  ),
    .size_t  (size_t  ),
    .id_t    (id_t    )
  ) i_pf_predictor (
    .clk_i                 (clk_i               ),
    .rst_ni                (rst_ni              ),
    .pe_req_i              (pe_req_i            ),
    .pe_req_valid_i        (pe_req_valid_i      ),
    .prefetchable_i        (prefetchable        ),
    .byte_stride_i         (byte_stride         ),
    .size_i                (classified_size     ),
    .is_strided_i          (is_strided          ),
    .predict_valid_o       (predict_valid       ),
    .predict_ready_i       (predict_ready       ),
    .predicted_addr_o      (predicted_addr      ),
    .predicted_size_o      (predicted_size      ),
    .predicted_is_strided_o(predicted_is_strided),
    .mispredict_o          (mispredict          )
  );

  assign flush = mispredict;

  // Throttling (v1 scope: only strided predictions ever become a real
  // predictive AR) now happens inside pf_predictor itself -- see its
  // predict_valid_o. No separate in-flight counter (distance N / cap M)
  // here either -- M is already enforced by pred_addr_fifo_full_i's
  // occupancy below. Add one only if M needs to differ from that FIFO's
  // depth.

  // Package the predicted address into a real, single-beat AXI AR with
  // id=1. size comes from the predictor's forwarded classification, not a
  // fresh read of pe_req_i -- this module has no business knowing the
  // instruction's internal field layout twice.
  axi_ar_t pred_ar;
  assign pred_ar = '{
    id     : 1,
    addr   : predicted_addr,
    len    : '0,
    size   : predicted_size,
    cache  : CACHE_MODIFIABLE,
    burst  : BURST_INCR,
    default: '0
  };

  // ---------------------------------------------------------------------
  // Pending-predictive-address tracker (see header comment).
  // ---------------------------------------------------------------------
  logic  pred_addr_fifo_push, pred_addr_fifo_pop;
  logic  pred_addr_fifo_full;
  addr_t pred_addr_fifo_addr_out;
  size_t pred_addr_fifo_size_out;
  logic  pred_addr_fifo_poisoned;

  pf_addr_fifo #(
    .Depth (PredAddrFifoDepth),
    .addr_t(addr_t           ),
    .size_t(size_t           )
  ) i_pred_addr_fifo (
    .clk_i         (clk_i                  ),
    .rst_ni        (rst_ni                 ),
    .push_valid_i  (pred_addr_fifo_push    ),
    .push_addr_i   (predicted_addr         ),
    .push_size_i   (predicted_size         ),
    .full_o        (pred_addr_fifo_full    ),
    .pop_i         (pred_addr_fifo_pop     ),
    .pop_addr_o    (pred_addr_fifo_addr_out),
    .pop_size_o    (pred_addr_fifo_size_out),
    .pop_poisoned_o(pred_addr_fifo_poisoned),
    .empty_o       (/* unused */          ),
    .inval_valid_i (cva6_inval_valid_i        ),
    .inval_addr_i  (cva6_inval_addr_i         ),
    .inval_len_i   (cva6_inval_len_i          ),
    .inval_size_i  (cva6_inval_size_i         )
  );

  // ---------------------------------------------------------------------
  // ROB + real-path handler. Arbitrates real vs. predictive AR for
  // the one physical AR_OUT channel (real always wins); releases to vldu
  // strictly in the order real ARs were issued, regardless of whether
  // each one was satisfied by a buffer hit or a real fetch.
  // ---------------------------------------------------------------------
  logic            lookup_valid;
  addr_t           lookup_addr;
  size_t           lookup_size;
  pf_entry_state_e lookup_state;
  axi_r_t          lookup_data;

  axi_r_t real_r;
  logic   real_r_valid, real_r_ready;

  pf_rob #(
    .Depth   (RobDepth),
    .axi_ar_t(axi_ar_t),
    .axi_r_t (axi_r_t ),
    .addr_t  (addr_t  ),
    .size_t  (size_t  )
  ) i_pf_rob (
    .clk_i                (clk_i              ),
    .rst_ni               (rst_ni             ),
    .flush_i              (rob_flush          ),
    .axi_ar_i             (axi_ar_i           ),
    .axi_ar_valid_i       (axi_ar_valid_i     ),
    .axi_ar_ready_o       (axi_ar_ready_o     ),
    .pred_ar_i            (pred_ar            ),
    .pred_ar_valid_i      (predict_valid && !pf_disable),
    .pred_ar_ready_o      (predict_ready      ),
    .pred_ar_fire_o       (pred_addr_fifo_push),
    .pred_addr_fifo_full_i(pred_addr_fifo_full),
    .axi_ar_o             (axi_ar_o           ),
    .axi_ar_valid_o       (axi_ar_valid_o     ),
    .axi_ar_ready_i       (axi_ar_ready_i     ),
    .axi_r_i              (real_r             ),
    .axi_r_valid_i        (real_r_valid       ),
    .axi_r_ready_o        (real_r_ready       ),
    .axi_r_o              (axi_r_o            ),
    .axi_r_valid_o        (axi_r_valid_o      ),
    .axi_r_ready_i        (axi_r_ready_i      ),
    .lookup_valid_o       (lookup_valid       ),
    .lookup_addr_o        (lookup_addr        ),
    .lookup_size_o        (lookup_size        ),
    .lookup_state_i       (lookup_state       ),
    .lookup_data_i        (lookup_data        )
  );

  // ---------------------------------------------------------------------
  // Split the one physical R channel by id; gate the fill on resp.
  // ---------------------------------------------------------------------
  logic  fill_valid;
  addr_t fill_addr;
  size_t fill_size;
  axi_r_t fill_data;

  pf_r_router #(
    .axi_r_t(axi_r_t),
    .addr_t (addr_t ),
    .size_t (size_t )
  ) i_pf_r_router (
    .r_i                  (axi_r_i                ),
    .r_valid_i            (axi_r_valid_i          ),
    .r_ready_o            (axi_r_ready_o          ),
    .real_r_o             (real_r                 ),
    .real_r_valid_o       (real_r_valid           ),
    .real_r_ready_i       (real_r_ready           ),
    .pred_addr_fifo_pop_o     (pred_addr_fifo_pop     ),
    .pred_addr_fifo_addr_i    (pred_addr_fifo_addr_out),
    .pred_addr_fifo_size_i    (pred_addr_fifo_size_out),
    .pred_addr_fifo_poisoned_i(pred_addr_fifo_poisoned),
    .fill_valid_o         (fill_valid             ),
    .fill_addr_o          (fill_addr              ),
    .fill_size_o          (fill_size              ),
    .fill_data_o          (fill_data              )
  );

  // ---------------------------------------------------------------------
  // Data buffer. Two states only (empty/valid) -- see pf_data_buffer.sv.
  // ---------------------------------------------------------------------
  pf_data_buffer #(
    .Depth (DataBufDepth),
    .addr_t(addr_t      ),
    .size_t(size_t      ),
    .data_t(axi_r_t     )
  ) i_pf_data_buffer (
    .clk_i         (clk_i       ),
    .rst_ni        (rst_ni      ),
    .flush_i       (flush       ),
    .lookup_valid_i(lookup_valid),
    .lookup_addr_i (lookup_addr ),
    .lookup_size_i (lookup_size ),
    .lookup_state_o(lookup_state),
    .lookup_data_o (lookup_data ),
    .fill_valid_i  (fill_valid  ),
    .fill_addr_i   (fill_addr   ),
    .fill_size_i   (fill_size   ),
    .fill_data_i   (fill_data   ),
    .inval_valid_i (cva6_inval_valid_i),
    .inval_addr_i  (cva6_inval_addr_i ),
    .inval_len_i   (cva6_inval_len_i  ),
    .inval_size_i  (cva6_inval_size_i )
  );

`ifndef SYNTHESIS
  // ---------------------------------------------------------------------
  // Simulation-only statistics. Read-only taps on signals above; nothing
  // here drives any functional signal. Printed once at end of simulation
  // when +pf_stats is given, as one "PF_STATS key=value ..." line.
  // ---------------------------------------------------------------------
  longint unsigned st_cycle;
  longint unsigned st_real_ar, st_real_hit, st_real_miss;
  longint unsigned st_pred_ar, st_fill, st_mispredict, st_new_insn;
  // A real miss whose address has a predictive fetch still in flight: the
  // case a third "in-flight" buffer state would turn into a wait.
  longint unsigned st_dup;
  longint unsigned st_max_outstanding;
  // Real-path round trip, AR accepted -> its last R beat released.
  longint unsigned st_lat_min, st_lat_sum, st_lat_cnt;
  longint unsigned st_issue_q[$];

  logic st_inflight_match;
  always_comb begin
    st_inflight_match = 1'b0;
    for (int unsigned i = 0; i < PredAddrFifoDepth; i++) begin
      if (i_pred_addr_fifo.valid_q[i] &&
          i_pred_addr_fifo.entry_q[i].addr == addr_t'(axi_ar_i.addr) &&
          i_pred_addr_fifo.entry_q[i].size == size_t'(axi_ar_i.size))
        st_inflight_match = 1'b1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_cycle           <= '0;
      st_real_ar         <= '0;
      st_real_hit        <= '0;
      st_real_miss       <= '0;
      st_pred_ar         <= '0;
      st_fill            <= '0;
      st_mispredict      <= '0;
      st_new_insn        <= '0;
      st_dup             <= '0;
      st_max_outstanding <= '0;
      st_lat_min         <= '1;
      st_lat_sum         <= '0;
      st_lat_cnt         <= '0;
    end else begin
      st_cycle <= st_cycle + 1;
      if (i_pf_rob.ar_fire) begin
        st_real_ar <= st_real_ar + 1;
        if (i_pf_rob.is_hit) st_real_hit  <= st_real_hit + 1;
        else                 st_real_miss <= st_real_miss + 1;
        if (!i_pf_rob.is_hit && st_inflight_match) st_dup <= st_dup + 1;
      end
      if (pred_addr_fifo_push)      st_pred_ar    <= st_pred_ar + 1;
      if (fill_valid)               st_fill       <= st_fill + 1;
      if (mispredict)               st_mispredict <= st_mispredict + 1;
      if (i_pf_predictor.new_insn)  st_new_insn   <= st_new_insn + 1;
      if (i_pf_rob.count_q > st_max_outstanding) st_max_outstanding <= i_pf_rob.count_q;

      if (i_pf_rob.real_ar_fire) st_issue_q.push_back(st_cycle);
      if (i_pf_rob.real_r_fire && i_pf_rob.r_last_beat && st_issue_q.size() != 0) begin
        automatic longint unsigned lat = st_cycle - st_issue_q.pop_front();
        st_lat_sum <= st_lat_sum + lat;
        st_lat_cnt <= st_lat_cnt + 1;
        if (lat < st_lat_min) st_lat_min <= lat;
      end
    end
  end

  final begin
    if ($test$plusargs("pf_stats")) begin
      $display("PF_STATS real_ar=%0d hit=%0d miss=%0d pred_ar=%0d fill=%0d mispredict=%0d new_insn=%0d dup=%0d max_outstanding=%0d lat_min=%0d lat_avg_x10=%0d",
               st_real_ar, st_real_hit, st_real_miss, st_pred_ar, st_fill, st_mispredict,
               st_new_insn, st_dup, st_max_outstanding,
               (st_lat_cnt != 0) ? st_lat_min : 0,
               (st_lat_cnt != 0) ? (st_lat_sum * 10) / st_lat_cnt : 0);
    end
  end
`endif

endmodule : prefetch_buffer
