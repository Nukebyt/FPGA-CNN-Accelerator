`timescale 1ns / 1ps
//
// cnn_accelerator_de10_top_tb: smoke test for the board wrapper's own
// sequencer/reset/display glue (not the algorithmic core, already covered
// by cnn_accelerator_tb.v). Shrinks DISPLAY_CYCLES so two full demo loops
// finish in a manageable number of simulated cycles, then checks that a
// known-good pooled result (max pooling, matching identity-kernel math
// would give -- here the real demo kernel/image are used, so this just
// checks the wrapper produces a defined, non-X result and completes two
// independent loops without hanging).
//
module cnn_accelerator_de10_top_tb;

    reg CLOCK_50;
    reg [1:0] KEY;
    reg [1:0] SW;
    wire [3:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;

    integer errors;

    cnn_accelerator_de10_top #(
        .DISPLAY_CYCLES(20),
        .RESET_HOLD(4)
    ) dut (
        .CLOCK_50(CLOCK_50), .KEY(KEY), .SW(SW),
        .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5)
    );

    initial CLOCK_50 = 0;
    always #10 CLOCK_50 = ~CLOCK_50; // 50 MHz

    initial begin
        errors = 0;
        KEY = 2'b00; // board reset asserted, KEY[1] idle-low during reset only
        SW  = 2'b00; // max pooling
        repeat (4) @(posedge CLOCK_50);
        KEY = 2'b11; // release reset; both keys idle (active low)

        // Poll frame_count directly (more robust than catching a
        // single-cycle LED pulse mid-transition) for two completed loops.
        wait (dut.frame_count === 8'd1);
        if (^dut.result_arr[0] === 1'bx) begin
            errors = errors + 1;
            $display("FAIL: result_arr[0] contains X bits after loop 1: %b", dut.result_arr[0]);
        end else begin
            $display("PASS: loop 1 done, result_arr[0] = %0d (0x%h)", dut.result_arr[0], dut.result_arr[0]);
        end

        // KEY[1] press should cycle the displayed result (dead code fixed:
        // display_sel now actually drives HEX3:HEX0 via shown_result).
        if (dut.display_sel !== 2'd0) begin
            errors = errors + 1;
            $display("FAIL: display_sel = %0d before any KEY[1] press, expected 0", dut.display_sel);
        end
        KEY[1] = 1'b0; @(posedge CLOCK_50); @(posedge CLOCK_50);
        KEY[1] = 1'b1; @(posedge CLOCK_50); @(posedge CLOCK_50);
        if (dut.display_sel !== 2'd1) begin
            errors = errors + 1;
            $display("FAIL: display_sel = %0d after one KEY[1] press, expected 1", dut.display_sel);
        end else begin
            $display("PASS: KEY[1] press cycled display_sel to %0d", dut.display_sel);
        end

        wait (dut.frame_count === 8'd2);
        $display("PASS: loop 2 done, frame_count = %0d", dut.frame_count);

        if (errors == 0)
            $display("ALL WRAPPER TESTS PASSED");
        else
            $display("%0d WRAPPER TEST(S) FAILED", errors);

        $finish;
    end

    initial begin
        #200000; // safety timeout
        $display("TIMEOUT: wrapper did not complete two demo loops");
        $finish;
    end

endmodule
