// Description:
// Throttle (Sec. 5.3): the one policy gate between predictor and pf_rob's
// predictive-AR arbitration input. v1 scope (Sec. 10.1): only strided
// (VLSE) predictions are allowed to become real predictive ARs -- unit-
// stride (VLE) predictions still run through classifier/predictor and
// build up confidence-FSM state (Sec. 10.1's observe-only stats), but are
// silently absorbed here, never reaching the AXI bus. Pure combinational
// gate, no state of its own.
//
// ponytail: distance N (Sec. 5.3, look multiple predictions ahead) has no
// home here -- pf_predictor only ever holds one pending prediction (a
// 1-deep skid register, see pf_predictor.sv), so there is nothing to look
// "N ahead" into yet; that would mean redesigning the predictor to hold a
// queue of predictions, not a throttle-level change. In-flight cap M is
// already enforced structurally by pred_addr_fifo_full_i (wired into
// pf_rob's own arbitration, see prefetch_buffer.sv) -- its depth
// (PredAddrFifoDepth, default 4) *is* M; a second, independent counter
// here would just recompute the same fact pred_addr_fifo already tracks
// via its own occupancy. Add a real counter only if M ever needs to
// differ from that FIFO's depth.

module pf_throttle (
    input  logic predict_valid_i,
    input  logic predicted_is_strided_i,
    output logic predict_valid_o,

    output logic predict_ready_o,
    input  logic predict_ready_i
  );

  // Non-strided predictions are accepted-and-dropped on the spot (ready=1
  // regardless of the real downstream ready) so pf_predictor's pending
  // state doesn't linger holding a prediction that will never be sent --
  // harmless either way (a new instruction overwrites it unconditionally,
  // see pf_predictor.sv), but this keeps it from sitting asserted for an
  // unbounded number of cycles between VLE instructions.
  assign predict_valid_o = predict_valid_i && predicted_is_strided_i;
  assign predict_ready_o = predicted_is_strided_i ? predict_ready_i : 1'b1;

endmodule : pf_throttle
