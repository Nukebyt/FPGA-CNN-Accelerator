`timescale 1ns / 1ps
//
// cnn_accelerator_de10_top: self-contained DE10-Standard bring-up wrapper
// for cnn_accelerator.v. No HPS/Linux/host PC involvement needed after
// programming -- a fixed 6x6 demo activation map and a fixed 3x3 kernel
// both live on-chip, a sequencer feeds them through the real core at full
// 50 MHz, and the four pooled results plus a loop counter are shown on
// the board's own LEDs and 7-segment displays.
//
// SW[1:0] selects pool_type live (00 max / 01 avg / 10 min), sampled once
// per loop so a switch flip takes effect on the next frame. KEY[0] is the
// board reset (active low, idle=1). KEY[1] cycles which of the 4 pooled
// results HEX3:HEX0 shows (also active low, edge-detected).
//
module cnn_accelerator_de10_top #(
    // Overridable only so a testbench can shrink DISPLAY_CYCLES for fast
    // simulation of this wrapper's sequencer -- the real board build must
    // use the default (~1s pause between frames at 50 MHz).
    parameter integer DISPLAY_CYCLES = 50_000_000,
    parameter integer RESET_HOLD     = 8
) (
    input  wire       CLOCK_50,
    input  wire [1:0] KEY,   // [0]: board reset (active low, idle=1)
                              // [1]: cycle displayed result (active low, idle=1)
    input  wire [1:0] SW,    // pool_type select

    output wire [3:0] LEDR,  // [0]=nonzero for the currently displayed result
                              // [1]=frame-done pulse
                              // [2]=streaming (loading the demo image)
                              // [3]=heartbeat (design alive / clocking)
    output wire [6:0] HEX0, HEX1, HEX2, HEX3, // selected pooled result, 4 hex digits
    output wire [6:0] HEX4, HEX5              // loop counter, 2 hex digits
);
    localparam N = 16, Q = 12, QSHIFT = 4, IMG = 6, K = 3, POOL = 2;
    localparam integer IMG_COUNT = IMG*IMG; // 36

    wire board_rstn = KEY[0];

    reg [1:0] pool_sel_r;
    always @(posedge CLOCK_50 or negedge board_rstn)
        if (!board_rstn) pool_sel_r <= 2'b00;
        else             pool_sel_r <= SW;

    // ---- On-chip demo activation map: a checkerboard (not a smooth ramp,
    // whose local neighborhoods are affine and cancel to exactly zero
    // under the sum-zero sharpen kernel below) so the demo kernel below
    // actually produces a visible nonzero response.
    function [N-1:0] demo_pixel;
        input [5:0] idx;
        reg [2:0] r, c;
        begin
            r = idx / 6;
            c = idx % 6;
            demo_pixel = (r[0] ^ c[0]) ? 16'sd0 : 16'sd4096; // Q12: 1.0 or 0.0
        end
    endfunction

    // ---- Fixed demo kernel: a normalized edge-emphasis kernel (Q12) ----
    function [K*K*N-1:0] demo_kernel;
        input dummy;
        reg [K*K*N-1:0] w;
        begin
            w = 0;
            w[0*N +: N] = -16'sd1024; w[1*N +: N] = -16'sd1024; w[2*N +: N] = -16'sd1024;
            w[3*N +: N] = -16'sd1024; w[4*N +: N] =  16'sd8192; w[5*N +: N] = -16'sd1024;
            w[6*N +: N] = -16'sd1024; w[7*N +: N] = -16'sd1024; w[8*N +: N] = -16'sd1024;
            demo_kernel = w;
        end
    endfunction

    reg               core_rst;
    reg               core_en;
    reg  [N-1:0]      core_activation_in;
    reg  [K*K*N-1:0]  core_weight;
    wire [N-1:0]      core_data_out;
    wire              core_valid_out, core_done;

    cnn_accelerator #(
        .N(N), .Q(Q), .QSHIFT(QSHIFT), .IMG(IMG), .K(K), .POOL(POOL)
    ) core (
        .clk(CLOCK_50), .rst(core_rst), .en(core_en),
        .activation_in(core_activation_in), .weight(core_weight),
        .pool_type(pool_sel_r),
        .data_out(core_data_out), .valid_out(core_valid_out), .done(core_done)
    );

    localparam [2:0] ST_RESET = 3'd0, ST_KICK = 3'd1, ST_FEED = 3'd2,
                      ST_WAIT  = 3'd3, ST_DISPLAY = 3'd4;
    reg [2:0]  state;
    reg [5:0]  feed_idx;
    reg [3:0]  reset_cnt;
    reg [31:0] display_cnt;
    reg [1:0]  result_idx;
    reg [N-1:0] result_arr [0:3];
    reg [7:0]  frame_count;
    reg        streaming_led;
    reg        frame_done_pulse;

    // KEY[1]: 2-stage synchronizer + falling-edge detect to cycle the
    // displayed result on each press.
    reg [1:0]  key1_sync;
    reg [1:0]  display_sel;
    integer    ri;

    always @(posedge CLOCK_50 or negedge board_rstn)
        if (!board_rstn) key1_sync <= 2'b11;
        else             key1_sync <= {key1_sync[0], KEY[1]};
    wire key1_pressed = (key1_sync == 2'b10);

    always @(posedge CLOCK_50 or negedge board_rstn) begin
        if (!board_rstn) begin
            state              <= ST_RESET;
            core_rst           <= 1'b1;
            core_en            <= 1'b0;
            core_activation_in <= {N{1'b0}};
            core_weight        <= demo_kernel(1'b0);
            feed_idx           <= 6'd0;
            reset_cnt          <= 4'd0;
            display_cnt        <= 32'd0;
            result_idx         <= 2'd0;
            for (ri = 0; ri < 4; ri = ri + 1)
                result_arr[ri] <= {N{1'b0}};
            frame_count        <= 8'd0;
            streaming_led      <= 1'b0;
            frame_done_pulse   <= 1'b0;
            display_sel        <= 2'd0;
        end else begin
            if (key1_pressed)
                display_sel <= display_sel + 2'd1;
            frame_done_pulse <= 1'b0;
            case (state)
                ST_RESET: begin
                    core_en <= 1'b0;
                    if (reset_cnt < RESET_HOLD) begin
                        core_rst  <= 1'b1;
                        reset_cnt <= reset_cnt + 4'd1;
                    end else begin
                        core_rst      <= 1'b0;
                        feed_idx      <= 6'd0;
                        streaming_led <= 1'b1;
                        state         <= ST_KICK;
                    end
                end

                ST_KICK: begin
                    core_weight        <= demo_kernel(1'b0);
                    core_activation_in <= demo_pixel(6'd0);
                    core_en            <= 1'b1;
                    feed_idx           <= 6'd1;
                    state              <= ST_FEED;
                end

                ST_FEED: begin
                    core_en <= 1'b0;
                    if (feed_idx < IMG_COUNT) begin
                        core_activation_in <= demo_pixel(feed_idx);
                        feed_idx <= feed_idx + 6'd1;
                    end
                    if (feed_idx == IMG_COUNT) begin
                        streaming_led <= 1'b0;
                        result_idx    <= 2'd0;
                        state         <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (core_valid_out) begin
                        result_arr[result_idx] <= core_data_out;
                        result_idx <= result_idx + 2'd1;
                    end
                    if (core_done) begin
                        display_cnt      <= 32'd0;
                        frame_done_pulse <= 1'b1;
                        frame_count      <= frame_count + 8'd1;
                        state            <= ST_DISPLAY;
                    end
                end

                ST_DISPLAY: begin
                    if (display_cnt < DISPLAY_CYCLES-1) begin
                        display_cnt <= display_cnt + 32'd1;
                    end else begin
                        core_rst  <= 1'b1;
                        reset_cnt <= 4'd0;
                        state     <= ST_RESET;
                    end
                end

                default: state <= ST_RESET;
            endcase
        end
    end

    // Heartbeat: toggles at ~1.5 Hz off the top bit of a free-running counter
    reg [25:0] hb_cnt;
    always @(posedge CLOCK_50 or negedge board_rstn)
        if (!board_rstn) hb_cnt <= 26'd0;
        else             hb_cnt <= hb_cnt + 26'd1;

    wire [N-1:0] shown_result = result_arr[display_sel];

    assign LEDR[0] = |shown_result;
    assign LEDR[1] = frame_done_pulse;
    assign LEDR[2] = streaming_led;
    assign LEDR[3] = hb_cnt[25];

    seg7_decoder d0 (.hex_in(shown_result[3:0]),  .seg(HEX0));
    seg7_decoder d1 (.hex_in(shown_result[7:4]),  .seg(HEX1));
    seg7_decoder d2 (.hex_in(shown_result[11:8]), .seg(HEX2));
    seg7_decoder d3 (.hex_in(shown_result[15:12]),.seg(HEX3));
    seg7_decoder d4 (.hex_in(frame_count[3:0]),   .seg(HEX4));
    seg7_decoder d5 (.hex_in(frame_count[7:4]),   .seg(HEX5));

endmodule
