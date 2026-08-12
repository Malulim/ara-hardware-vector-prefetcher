// Address tracking FIFO. AXI's R channel never echoes back the request
// address, so this remembers {addr, size} for every outstanding
// predictive AR, in issue order, until its R beat arrives.
//
// Pure FIFO semantics: pop order equals push order. When to push/pop is
// the caller's job (pf_throttle on push, pf_r_router on pop), kept
// separate so a bug in "is this a real pop opportunity" can't be confused
// with a bug in "did the FIFO preserve order."
//
// Backed by an explicit head/tail array rather than fifo_v3: a CVA6 store
// can land on an address this FIFO is still holding (the predictive AR
// was issued before the store, so pf_data_buffer has no entry yet for
// inval to clear), but the stale R data is still going to arrive and get
// cached after the store landed. Content-addressable poisoning closes
// that window: an inval_* hit marks the entry poisoned_q instead of
// removing it (removal would desync pop order from push order), and
// pop_poisoned_o tells pf_r_router to discard that entry's data instead
// of caching it. fifo_v3 doesn't expose its storage for that kind of
// side compare, hence the rewrite.

module pf_addr_fifo import pf_pkg::*; #(
    parameter int  unsigned Depth  = 4,
    parameter type          addr_t = logic,
    parameter type          size_t = logic,
    // Dependent parameters. DO NOT CHANGE!
    localparam int unsigned IdxWidth   = (Depth > 1) ? $clog2(Depth) : 1,
    localparam int unsigned CountWidth = $clog2(Depth + 1)
  ) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,

    input  logic  push_valid_i,
    input  addr_t push_addr_i,
    input  size_t push_size_i,
    output logic  full_o,

    input  logic  pop_i,
    output addr_t pop_addr_o,
    output size_t pop_size_o,
    output logic  pop_poisoned_o,
    output logic  empty_o,

    // Coherency: see header comment. Same {addr, len, size} shape as
    // pf_data_buffer.sv's inval_* ports -- both are driven from the same
    // CVA6 store snoop, see prefetch_buffer.sv.
    input  logic          inval_valid_i,
    input  addr_t         inval_addr_i,
    input  axi_pkg::len_t inval_len_i,
    input  size_t         inval_size_i
  );

  typedef struct packed {
    addr_t addr;
    size_t size;
  } entry_t;

  entry_t [Depth-1:0] entry_q;
  logic   [Depth-1:0] valid_q;
  logic   [Depth-1:0] poisoned_q;

  logic [IdxWidth-1:0]   head_ptr_d, head_ptr_q;
  logic [IdxWidth-1:0]   tail_ptr_d, tail_ptr_q;
  logic [CountWidth-1:0] count_d, count_q;

  assign full_o  = (count_q == CountWidth'(Depth));
  assign empty_o = (count_q == CountWidth'(0));

  logic push_fire, pop_fire;
  assign push_fire = push_valid_i && !full_o;
  assign pop_fire   = pop_i && !empty_o;

  assign pop_addr_o     = entry_q[head_ptr_q].addr;
  assign pop_size_o     = entry_q[head_ptr_q].size;
  assign pop_poisoned_o = poisoned_q[head_ptr_q];

  // One entry is always exactly one predictive (single-beat) AR (see
  // prefetch_buffer.sv: pred_ar always has len=0), so its byte range is
  // [addr, addr + 2^size).
  logic [Depth-1:0] inval_match;
  for (genvar i = 0; i < Depth; i++) begin : g_inval
    assign inval_match[i] = inval_valid_i && valid_q[i]
                              && ranges_overlap(
                                   64'(entry_q[i].addr), 64'd1 << entry_q[i].size,
                                   64'(inval_addr_i), (64'(inval_len_i) + 64'd1) << inval_size_i
                                 );
  end

  always_comb begin
    head_ptr_d = head_ptr_q;
    tail_ptr_d = tail_ptr_q;
    count_d    = count_q;
    if (push_fire) tail_ptr_d = (tail_ptr_q == IdxWidth'(Depth - 1)) ? '0 : tail_ptr_q + 1;
    if (pop_fire)  head_ptr_d = (head_ptr_q == IdxWidth'(Depth - 1)) ? '0 : head_ptr_q + 1;
    unique case ({push_fire, pop_fire})
      2'b10:   count_d = count_q + CountWidth'(1);
      2'b01:   count_d = count_q - CountWidth'(1);
      default: count_d = count_q;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_q    <= '0;
      valid_q    <= '0;
      poisoned_q <= '0;
      head_ptr_q <= '0;
      tail_ptr_q <= '0;
      count_q    <= '0;
    end else if (flush_i) begin
      valid_q    <= '0;
      poisoned_q <= '0;
      head_ptr_q <= '0;
      tail_ptr_q <= '0;
      count_q    <= '0;
    end else begin
      if (push_fire) begin
        entry_q[tail_ptr_q]    <= entry_t'{addr: push_addr_i, size: push_size_i};
        valid_q[tail_ptr_q]    <= 1'b1;
        poisoned_q[tail_ptr_q] <= 1'b0;
      end
      if (pop_fire) valid_q[head_ptr_q] <= 1'b0;
      for (int unsigned i = 0; i < Depth; i++) begin
        if (inval_match[i]) poisoned_q[i] <= 1'b1;
      end
      head_ptr_q <= head_ptr_d;
      tail_ptr_q <= tail_ptr_d;
      count_q    <= count_d;
    end
  end

endmodule : pf_addr_fifo
