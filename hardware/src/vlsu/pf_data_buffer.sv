// Fully-associative prefetch data buffer. Entries are only ever {empty,
// valid} -- there's no "in-flight" state. An address with a predictive AR
// outstanding but no R data yet simply isn't in this buffer; a query
// against it reports EMPTY, same as an address never requested, and falls
// through the existing miss path with no extra branch. Counting
// outstanding predictive ARs (for throttling) is a separate concern --
// see prefetch_buffer.sv, which gets it for free from pred_addr_fifo's
// full_o instead of a second, redundant counter.
//
// Entry is {addr, size, data, state}, not just {addr, data, state}: a hit
// requires addr == query_addr AND size == query_size. Address-only
// matching would let e.g. a vlse32 prefetch at address A satisfy a later
// vlse64 request at the same address, silently handing back data sized
// for the wrong element width. FIFO replacement on fill, no dedup against
// an already-cached {addr,size} -- a lookup only needs *a* matching valid
// entry, not a unique one.

module pf_data_buffer import pf_pkg::*; #(
    parameter int  unsigned Depth  = 4,
    parameter type          addr_t = logic,
    parameter type          size_t = logic,
    parameter type          data_t = logic,
    // Dependent parameters. DO NOT CHANGE!
    localparam int unsigned IdxWidth = (Depth > 1) ? $clog2(Depth) : 1
  ) (
    input  logic clk_i,
    input  logic rst_ni,
    // A predictor mismatch discards resident guesses. This is a cleanup
    // policy, not a correctness requirement: lookup still requires an
    // exact {addr, size} match. In-flight metadata is deliberately kept
    // in pf_addr_fifo until the corresponding R response returns.
    input  logic flush_i,

    // Lookup: queried by pf_rob for every incoming real AR.
    input  logic            lookup_valid_i,
    input  addr_t           lookup_addr_i,
    input  size_t           lookup_size_i,
    output pf_entry_state_e lookup_state_o,
    output data_t            lookup_data_o,

    // Fill a slot once its prefetch R data arrives (pf_r_router, id=1,
    // already gated on RESP_OKAY upstream of this port).
    input  logic  fill_valid_i,
    input  addr_t fill_addr_i,
    input  size_t fill_size_i,
    input  data_t fill_data_i,

    // Coherency: a CVA6 store landed on [inval_addr_i, inval_addr_i +
    // bytes(inval_len_i, inval_size_i)) -- clear every entry whose byte
    // range overlaps it, mirroring axi_inval_filter.sv's ARA->CVA6
    // direction but keyed on exact address-range overlap rather than
    // cache-line/set-index, since this buffer is small and fully
    // associative rather than a real cache (see pf_pkg::ranges_overlap).
    // Takes priority over fill_valid_i landing on the same slot the same
    // cycle -- see the always_ff below.
    input  logic         inval_valid_i,
    input  addr_t        inval_addr_i,
    input  axi_pkg::len_t inval_len_i,
    input  size_t         inval_size_i
  );

  addr_t           [Depth-1:0] addr_q;
  size_t           [Depth-1:0] size_q;
  data_t           [Depth-1:0] data_q;
  pf_entry_state_e [Depth-1:0] state_q;

  logic [IdxWidth-1:0] replace_ptr_d, replace_ptr_q;
  assign replace_ptr_d = (replace_ptr_q == IdxWidth'(Depth - 1)) ? '0 : replace_ptr_q + 1;

  logic [Depth-1:0] hit_match;
  for (genvar i = 0; i < Depth; i++) begin : g_match
    assign hit_match[i] = (state_q[i] == PF_ENTRY_VALID)
                            && (addr_q[i] == lookup_addr_i)
                            && (size_q[i] == lookup_size_i);
  end

  // One entry is always exactly one AXI beat (see header comment), so its
  // byte range is [addr_q[i], addr_q[i] + 2^size_q[i]).
  logic [Depth-1:0] inval_match;
  for (genvar i = 0; i < Depth; i++) begin : g_inval
    assign inval_match[i] = inval_valid_i && (state_q[i] == PF_ENTRY_VALID)
                              && ranges_overlap(
                                   64'(addr_q[i]), 64'd1 << size_q[i],
                                   64'(inval_addr_i), (64'(inval_len_i) + 64'd1) << inval_size_i
                                 );
  end

  always_comb begin
    lookup_state_o = PF_ENTRY_EMPTY;
    lookup_data_o  = '0;
    for (int unsigned i = 0; i < Depth; i++) begin
      if (lookup_valid_i && hit_match[i]) begin
        lookup_state_o = PF_ENTRY_VALID;
        lookup_data_o  = data_q[i];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= '0;
      addr_q        <= '0;
      size_q        <= '0;
      data_q        <= '0;
      replace_ptr_q <= '0;
    end else if (flush_i) begin
      state_q       <= '0;
      replace_ptr_q <= '0;
    end else begin
      // A store invalidating the very slot a fill would land in this
      // cycle wins: dropping a predictive fetch is a missed prefetch
      // opportunity (same risk class pf_r_router already accepts for a
      // non-OKAY resp), caching it anyway would be a correctness bug.
      if (fill_valid_i && !inval_match[replace_ptr_q]) begin
        state_q[replace_ptr_q] <= PF_ENTRY_VALID;
        addr_q[replace_ptr_q]  <= fill_addr_i;
        size_q[replace_ptr_q]  <= fill_size_i;
        data_q[replace_ptr_q]  <= fill_data_i;
        replace_ptr_q          <= replace_ptr_d;
      end
      for (int unsigned i = 0; i < Depth; i++) begin
        if (inval_match[i]) state_q[i] <= PF_ENTRY_EMPTY;
      end
    end
  end

endmodule : pf_data_buffer
