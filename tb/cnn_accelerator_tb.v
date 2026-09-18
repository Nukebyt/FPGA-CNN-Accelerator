`timescale 1ns / 1ps
//
// cnn_accelerator_tb: self-checking testbench. Feeds a fixed 6x6 test
// image through an identity-center 3x3 kernel (so the pre-quantization
// convolution result is exactly the window's center pixel -- easy to
// hand-verify) and checks the streamed pooled output against
// independently hand-computed expected values for all three pooling
// modes (max / average / min).
//
module cnn_accelerator_tb;

    localparam N      = 16;
    localparam Q      = 12;
    localparam QSHIFT = 4;
    localparam IMG    = 6;
    localparam K      = 3;
    localparam POOL   = 2;

    localparam IMG_COUNT  = IMG*IMG;
    localparam POOL_COUNT = 4;

    reg clk, rst, en;
    reg [N-1:0] activation_in;
    reg [(K*K*N)-1:0] weight;
    reg [1:0] pool_type;
    wire [N-1:0] data_out;
    wire valid_out, done;

    integer errors;
    integer i;

    reg [N-1:0] test_img [0:IMG_COUNT-1];
    reg [N-1:0] captured [0:POOL_COUNT-1];
    integer cap_idx;

    cnn_accelerator #(
        .N(N), .Q(Q), .QSHIFT(QSHIFT), .IMG(IMG), .K(K), .POOL(POOL)
    ) dut (
        .clk(clk), .rst(rst), .en(en),
        .activation_in(activation_in),
        .weight(weight),
        .pool_type(pool_type),
        .data_out(data_out),
        .valid_out(valid_out),
        .done(done)
    );

    // 50 MHz-equivalent free-running clock for simulation
    initial clk = 0;
    always #5 clk = ~clk;

    // Identity-center 3x3 kernel: only the center tap is 1.0 in Q12
    // (4096), so conv_raw at every window == the window's center pixel.
    function [K*K*N-1:0] identity_kernel;
        input dummy;
        reg [K*K*N-1:0] w;
        begin
            w = 0;
            w[4*N +: N] = 16'd4096; // center tap, Q12 1.0
            identity_kernel = w;
        end
    endfunction

    task run_case;
        input [1:0] sel_pool_type;
        input [N-1:0] exp0, exp1, exp2, exp3;
        begin
            rst = 1;
            en  = 0;
            activation_in = 0;
            @(posedge clk); @(posedge clk);
            rst = 0;
            @(posedge clk);

            weight    = identity_kernel(1'b0);
            pool_type = sel_pool_type;
            en        = 1;
            @(posedge clk); // IDLE -> LOAD, latches weight_reg/pool_type_reg

            for (i = 0; i < IMG_COUNT; i = i + 1) begin
                activation_in = test_img[i];
                en = 0;
                @(posedge clk);
            end

            cap_idx = 0;
            while (!done) begin
                @(posedge clk);
                if (valid_out) begin
                    captured[cap_idx] = data_out;
                    cap_idx = cap_idx + 1;
                end
            end

            check(sel_pool_type, 0, captured[0], exp0);
            check(sel_pool_type, 1, captured[1], exp1);
            check(sel_pool_type, 2, captured[2], exp2);
            check(sel_pool_type, 3, captured[3], exp3);
        end
    endtask

    task check;
        input [1:0] pt;
        input integer idx;
        input [N-1:0] got;
        input [N-1:0] exp;
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL pool_type=%0d idx=%0d: got=%0d expected=%0d", pt, idx, got, exp);
            end else begin
                $display("PASS pool_type=%0d idx=%0d: got=%0d as expected", pt, idx, got);
            end
        end
    endtask

    initial begin
        errors = 0;
        for (i = 0; i < IMG_COUNT; i = i + 1)
            test_img[i] = i[N-1:0];

        // pool_type=00 (max): [0, 16, 16, 16]
        run_case(2'b00, 16'd0, 16'd16, 16'd16, 16'd16);
        // pool_type=01 (avg): [0, 4, 16, 16]
        run_case(2'b01, 16'd0, 16'd4,  16'd16, 16'd16);
        // pool_type=10 (min): [0, 0, 16, 16]
        run_case(2'b10, 16'd0, 16'd0,  16'd16, 16'd16);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d TEST(S) FAILED", errors);

        $finish;
    end

endmodule
