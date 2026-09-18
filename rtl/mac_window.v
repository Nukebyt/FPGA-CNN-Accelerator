`timescale 1ns / 1ps
//
// mac_window: combinational KxK multiply-accumulate for one convolution
// output position. Sums all K*K signed products in full precision before
// a single rescale-and-saturate step back down to N bits, instead of
// shifting each product individually -- this keeps one extra generation
// of precision through the accumulation.
//
// window_flat / kernel_flat pack K*K signed N-bit lanes, lane i occupying
// bits [i*N +: N], lowest lane first.
//
module mac_window #(
    parameter N = 16,   // operand width (Qx.Q fixed point)
    parameter Q = 12,   // fractional bits
    parameter K = 3      // window side length
) (
    input  wire [K*K*N-1:0] window_flat,
    input  wire [K*K*N-1:0] kernel_flat,
    output wire signed [N-1:0] result
);

    localparam integer ACC_W = 2*N + 8; // headroom for K*K partial-product growth

    function signed [ACC_W-1:0] sum_products;
        input [K*K*N-1:0] win;
        input [K*K*N-1:0] ker;
        integer i;
        reg signed [ACC_W-1:0] acc;
        begin
            acc = 0;
            for (i = 0; i < K*K; i = i + 1)
                acc = acc + ($signed(win[i*N +: N]) * $signed(ker[i*N +: N]));
            sum_products = acc;
        end
    endfunction

    wire signed [ACC_W-1:0] acc_full = sum_products(window_flat, kernel_flat);
    wire signed [ACC_W-1:0] acc_scaled = acc_full >>> Q;

    localparam signed [N-1:0] SAT_MAX = {1'b0, {(N-1){1'b1}}};
    localparam signed [N-1:0] SAT_MIN = {1'b1, {(N-1){1'b0}}};

    assign result = (acc_scaled > $signed({{(ACC_W-N){SAT_MAX[N-1]}}, SAT_MAX})) ? SAT_MAX :
                     (acc_scaled < $signed({{(ACC_W-N){SAT_MIN[N-1]}}, SAT_MIN})) ? SAT_MIN :
                     acc_scaled[N-1:0];

endmodule
