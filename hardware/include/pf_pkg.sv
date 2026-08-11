// Description:
// Shared types for Ara's vector prefetcher (hardware/src/vlsu/pf_*.sv).

package pf_pkg;

  // State of one pf_data_buffer entry. Deliberately two-valued, not three:
  // an entry is only ever created when its R data actually lands, never
  // pre-allocated the moment a predictive AR is issued. There is no
  // window where an address is "known to be in flight but not yet
  // valid" as far as the data buffer is concerned -- a query during that
  // window simply reports EMPTY, which is indistinguishable from "never
  // requested" and is handled by the existing miss path with no extra
  // branch. Counting how many predictive ARs are currently outstanding
  // (for throttling) is a separate, address-agnostic concern that lives
  // in its own counter, not in this state machine -- see pf_predictor.sv.
  typedef enum logic {
    PF_ENTRY_EMPTY,
    PF_ENTRY_VALID
  } pf_entry_state_e;

  // Confidence FSM state (Sec. 5.2). NO_PRED: pattern not (yet, or no
  // longer) trusted, predictor still tracks it but issues no predictive
  // AR. TRANSIENT/STEADY: at least one confirmed-correct prediction in a
  // row, predictive ARs are issued in both. A single mispredict drops
  // straight back to NO_PRED from either TRANSIENT or STEADY -- not a
  // gradual step-down -- see pf_predictor.sv.
  typedef enum logic [1:0] {
    PF_CONF_NO_PRED,
    PF_CONF_TRANSIENT,
    PF_CONF_STEADY
  } pf_confidence_e;

  // Byte-range overlap test shared by pf_data_buffer.sv (invalidating
  // cached entries) and pf_addr_fifo.sv (poisoning in-flight predictive
  // fetches) when a CVA6 store lands on an address either of them is
  // holding. Widened to 64 bits so callers can pass addr_t/size_t values
  // of whatever width their AXI config uses without the caller having to
  // reason about truncation -- same reasoning as pf_predictor.sv's
  // predicted_addr_wide.
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
