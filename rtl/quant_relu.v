`timescale 1ns / 1ps
//
// quant_relu: fused post-convolution stage. Quantizes by truncating the
// bottom QSHIFT fractional bits (cuts switching activity / downstream
// bit-width without changing the fixed-point scale), then applies ReLU
// by zeroing anything with the sign bit set.
//
module quant_relu #(
    parameter N      = 16,
    parameter QSHIFT = 4
) (
    input  wire [N-1:0] din,
    output wire [N-1:0] dout
);

    wire [N-1:0] quantized = {din[N-1:QSHIFT], {QSHIFT{1'b0}}};
    assign dout = quantized[N-1] ? {N{1'b0}} : quantized;

endmodule
