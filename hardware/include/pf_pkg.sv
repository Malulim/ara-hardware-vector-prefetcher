// Shared types for Ara's vector prefetcher (hardware/src/vlsu/pf_*.sv).

package pf_pkg;

  // Two-valued, not three: an entry is created only when its R data
  // lands, never pre-allocated at AR issue, so there's no "in flight but
  // not valid" state to represent -- see pf_predictor.sv.
  typedef enum logic {
    PF_ENTRY_EMPTY,
    PF_ENTRY_VALID
  } pf_entry_state_e;

  // Confidence FSM. NO_PRED issues no predictive AR;
  // TRANSIENT/STEADY do. A mispredict drops straight to NO_PRED from
  // either state, not a gradual step-down -- see pf_predictor.sv.
  typedef enum logic [1:0] {
    PF_CONF_NO_PRED,
    PF_CONF_TRANSIENT,
    PF_CONF_STEADY
  } pf_confidence_e;

  // Byte-range overlap, shared by pf_data_buffer.sv and pf_addr_fifo.sv
  // to detect a CVA6 store landing on an address they're holding.
  // Widened to 64 bits so callers don't have to reason about truncation
  // for whatever addr_t/size_t width their AXI config uses.
  function automatic logic ranges_overlap(
      logic [63:0] a_addr, logic [63:0] a_len,
      logic [63:0] b_addr, logic [63:0] b_len
    );
    logic [63:0] a_end, b_end;
    a_end = a_addr + a_len - 64'd1;
    b_end = b_addr + b_len - 64'd1;
    return (a_addr <= b_end) && (b_addr <= a_end);
  endfunction

endpackage : pf_pkg
