`timescale 1ns / 1ps
//
// pool_unit: combinational 2x2 pooling with runtime-selectable reduction.
// pool_type: 00 = max, 01 = average, 10 = min, 11 = max (fallback).
//
module pool_unit #(
    parameter N = 16
) (
    input  wire [N-1:0] a, b, c, d,
    input  wire [1:0]   pool_type,
    output reg  [N-1:0] result
);

    wire signed [N-1:0] sa = a, sb = b, sc = c, sd = d;

    wire signed [N-1:0] max_ab = (sa > sb) ? sa : sb;
    wire signed [N-1:0] max_cd = (sc > sd) ? sc : sd;
    wire signed [N-1:0] max_all = (max_ab > max_cd) ? max_ab : max_cd;

    wire signed [N-1:0] min_ab = (sa < sb) ? sa : sb;
    wire signed [N-1:0] min_cd = (sc < sd) ? sc : sd;
    wire signed [N-1:0] min_all = (min_ab < min_cd) ? min_ab : min_cd;

    wire signed [N+1:0] sum4 = sa + sb + sc + sd;
    wire signed [N+1:0] avg_full = sum4 >>> 2;

    always @(*) begin
        case (pool_type)
            2'b00: result = max_all;
            2'b01: result = avg_full[N-1:0];
            2'b10: result = min_all;
            default: result = max_all;
        endcase
    end

endmodule
