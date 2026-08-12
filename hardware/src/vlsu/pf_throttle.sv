// Policy gate between predictor and pf_rob's predictive-AR arbitration.
// v1 only forwards strided (VLSE) predictions; unit-
// stride (VLE) predictions still update confidence-FSM state but are
// absorbed here and never reach the AXI bus.
//
// NOTE: no separate in-flight counter (distance N / cap M) here -- M is
// already enforced by pred_addr_fifo_full_i's occupancy (see
// prefetch_buffer.sv). Add one only if M needs to differ from that FIFO's
// depth.

module pf_throttle (
    input  logic predict_valid_i,
    input  logic predicted_is_strided_i,
    output logic predict_valid_o,

    output logic predict_ready_o,
    input  logic predict_ready_i
  );

  // Non-strided predictions are accepted-and-dropped (ready=1 regardless
  // of downstream ready) so pf_predictor's pending slot isn't held by a
  // prediction that will never be sent.
  assign predict_valid_o = predict_valid_i && predicted_is_strided_i;
  assign predict_ready_o = predicted_is_strided_i ? predict_ready_i : 1'b1;

endmodule : pf_throttle
