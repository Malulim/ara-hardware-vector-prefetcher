// Address prediction + confidence FSM.
// predicted_next_base = scalar_op + vl * byte_stride for both VLE and
// VLSE: expanding the vstart terms shows they cancel algebraically, so
// vstart needs no special-casing here (only vl's own extremes -- 0 and
// VLMAX -- are real boundary cases).
//
// size_i/size_o, is_strided_i/predicted_is_strided_o: forwarded as-is
// alongside the predicted address, latched the same cycle as new_insn.
// Never re-derived from pe_req_i -- pf_classifier already computed them
// once, and reading pe_req fields in two places for two outputs is
// exactly the kind of thing that drifts apart silently later.
//
// Confidence FSM: every new_insn, checks whether the address predicted
// *last* time (pending_addr_q, before this cycle overwrites it) matches
// this instruction's actual scalar_op. A match advances
// NO_PRED -> TRANSIENT -> STEADY (saturating); a miss drops straight back
// to NO_PRED from either state and pulses mispredict_o for one cycle.
// predict_valid_o only asserts once the *new* state (conf_d) is
// TRANSIENT or STEADY. address/size/is_strided are still latched every
// new_insn regardless of confidence, both as next time's comparison
// basis and so pf_throttle sees a consistent is_strided alongside
// whatever address eventually does go valid.
//
// Holds at most one pending prediction via a valid/ready handshake (the
// 1-deep skid register pf_rob's AR arbitration assumes its caller has):
// the predictive AR can lose arbitration to real traffic for an unbounded
// number of cycles, so the prediction must stay live until accepted. If a
// new qualifying instruction arrives first, the old prediction is simply
// dropped -- a missed prefetch opportunity, not a correctness bug.

module pf_predictor import pf_pkg::*; #(
    parameter type pe_req_t = logic,
    parameter type stride_t = logic,
    parameter type addr_t   = logic,
    parameter type size_t   = logic,
    parameter type id_t     = logic
  ) (
    input  logic    clk_i,
    input  logic    rst_ni,

    input  pe_req_t pe_req_i,
    input  logic    pe_req_valid_i,
    input  logic    prefetchable_i,
    input  stride_t byte_stride_i,
    input  size_t   size_i,
    input  logic    is_strided_i,

    output logic    predict_valid_o,
    input  logic    predict_ready_i,
    output addr_t   predicted_addr_o,
    output size_t   predicted_size_o,
    output logic    predicted_is_strided_o,

    // Pulses for one cycle the same cycle a mispredict is detected --
    // wired by prefetch_buffer.sv into flushing the predictive-side state
    // (pf_addr_fifo, pf_data_buffer). Deliberately NOT wired to pf_rob:
    // pf_rob also tracks real in-flight misses that have nothing to do
    // with whether this stride guess panned out, and clearing its slots
    // out from under an outstanding real AR would desync it from a real R
    // that is still going to arrive on the bus.
    output logic    mispredict_o
  );

  // addrgen can hold pe_req_valid_i/pe_req_i stable across many cycles while
  // it works through one instruction's AR issuance (e.g. a unit-stride
  // burst split across a page boundary). "valid && prefetchable" alone
  // would re-fire every one of those cycles. An instruction's id cannot be
  // reused by the sequencer until the previous holder of that id has fully
  // retired, so "id changed since the last prediction we fired" is a safe
  // new-instruction edge detector that does not require duplicating
  // addrgen's private vinsn_running_q state.
  id_t  last_id_q;
  logic last_id_valid_q;

  logic new_insn;
  assign new_insn = pe_req_valid_i && prefetchable_i &&
                     (!last_id_valid_q || (pe_req_i.id != last_id_q));

  // Compute in a generously wide temporary so neither operand's native
  // width can silently truncate the product before the final cast down
  // to addr_t.
  logic [127:0] predicted_addr_wide;
  assign predicted_addr_wide = 128'(pe_req_i.scalar_op) + 128'(pe_req_i.vl) * 128'(byte_stride_i);

  logic  pending_valid_q;
  addr_t pending_addr_q;
  size_t pending_size_q;
  logic  pending_is_strided_q;

  assign predict_valid_o        = pending_valid_q;
  assign predicted_addr_o       = pending_addr_q;
  assign predicted_size_o       = pending_size_q;
  assign predicted_is_strided_o = pending_is_strided_q;

  // Confidence FSM (see header comment). Reuses last_id_valid_q -- already
  // "have we fired at least one prediction before" by construction, since
  // it is set the same cycle and by the same new_insn condition that
  // latches pending_addr_q -- rather than keeping a second register that
  // would only ever equal it.
  pf_confidence_e conf_q;

  logic was_correct;
  assign was_correct = last_id_valid_q && (addr_t'(pe_req_i.scalar_op) == pending_addr_q);

  logic mispredict;
  assign mispredict   = new_insn && last_id_valid_q && !was_correct;
  assign mispredict_o = mispredict;

  pf_confidence_e conf_d;
  always_comb begin
    conf_d = conf_q;
    if (new_insn) begin
      if (!last_id_valid_q) begin
        conf_d = PF_CONF_NO_PRED;
      end else if (was_correct) begin
        unique case (conf_q)
          PF_CONF_NO_PRED:   conf_d = PF_CONF_TRANSIENT;
          PF_CONF_TRANSIENT: conf_d = PF_CONF_STEADY;
          PF_CONF_STEADY:    conf_d = PF_CONF_STEADY;
          default:           conf_d = PF_CONF_NO_PRED;
        endcase
      end else begin
        conf_d = PF_CONF_NO_PRED;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      last_id_q            <= '0;
      last_id_valid_q       <= 1'b0;
      pending_valid_q       <= 1'b0;
      pending_addr_q        <= '0;
      pending_size_q        <= '0;
      pending_is_strided_q  <= 1'b0;
      conf_q                <= PF_CONF_NO_PRED;
    end else begin
      if (new_insn) begin
        last_id_q            <= pe_req_i.id;
        last_id_valid_q       <= 1'b1;
        // Latched regardless of conf_d: this is both the comparison basis
        // for next time's was_correct check, and what throttle sees
        // alongside predict_valid_o whenever it does go valid.
        pending_addr_q        <= addr_t'(predicted_addr_wide);
        pending_size_q        <= size_i;
        pending_is_strided_q  <= is_strided_i;
        pending_valid_q       <= (conf_d != PF_CONF_NO_PRED);
        conf_q                <= conf_d;
      end else if (pending_valid_q && predict_ready_i) begin
        pending_valid_q <= 1'b0;
      end
    end
  end

endmodule : pf_predictor
