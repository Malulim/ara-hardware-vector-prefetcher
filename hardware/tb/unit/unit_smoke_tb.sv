module unit_smoke_tb;
  logic clk;

  initial begin
    clk = 1'b0;
    repeat (20) #5 clk = ~clk;
    $finish;
  end
endmodule
