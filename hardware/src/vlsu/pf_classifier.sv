// Pattern classification. Purely combinational: RVV gives stride directly
// in the instruction encoding, so there's nothing to infer here, unlike a
// classic IP-stride prefetcher. VLE/VLSE are prefetchable; indexed loads
// and stores are not. Segment-derived micro-ops are not separately tagged
// here: Ara's segment sequencer presents them as VLE or VLSE, so they follow
// the corresponding classification below.
//
// size_o mirrors pe_req_i.vtype.vsew (the AXI size encoding Ara's own
// addrgen already uses) so downstream hit comparisons can check
// {addr, size}, not just addr -- two accesses to the same address at
// different element widths must not alias. Computed independently of
// byte_stride_o so a stride bug can never masquerade as a size bug.
//
// is_strided_o: the one extra bit pf_predictor needs to gate predict_valid_o -- only VLSE
// predictions become real predictive ARs, VLE stays observe-only. Decoded
// here, not re-derived downstream, for the same reason as size_o.

module pf_classifier import ara_pkg::*; #(
    parameter type pe_req_t = logic,
    parameter type stride_t = logic,
    parameter type size_t   = logic
  ) (
    input  pe_req_t pe_req_i,
    output logic    prefetchable_o,
    output stride_t byte_stride_o,
    output size_t   size_o,
    output logic    is_strided_o
  );

  always_comb begin
    prefetchable_o = 1'b0;
    byte_stride_o  = '0;
    size_o         = '0;
    is_strided_o   = 1'b0;

    case (pe_req_i.op)
      VLE: begin
        prefetchable_o = 1'b1;
        byte_stride_o  = stride_t'(1) << pe_req_i.vtype.vsew;
        size_o         = size_t'(pe_req_i.vtype.vsew);
      end
      VLSE: begin
        prefetchable_o = 1'b1;
        byte_stride_o  = stride_t'(pe_req_i.stride);
        size_o         = size_t'(pe_req_i.vtype.vsew);
        is_strided_o   = 1'b1;
      end
      default: ; // Indexed loads and all stores: never prefetched
    endcase
  end

endmodule : pf_classifier
