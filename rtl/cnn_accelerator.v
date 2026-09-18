`timescale 1ns / 1ps
//
// cnn_accelerator: top-level pipeline for a small CNN layer
// (convolution -> quantize -> ReLU -> pool).
//
// Architecture: the whole IMGxIMG activation map is shifted in and
// latched first, then every convolution window is evaluated in parallel
// (one mac_window + quant_relu pair per output position) rather than
// streamed through a sliding line buffer. That is affordable at this
// IMG/K size and keeps the datapath combinational apart from three
// single-cycle register stages (load -> conv -> pool -> stream out).
//
module cnn_accelerator #(
    parameter N      = 16,  // operand width, fixed point
    parameter Q      = 12,  // fractional bits
    parameter QSHIFT = 4,   // quantization: LSBs truncated post-conv
    parameter IMG    = 6,   // input activation map is IMG x IMG
    parameter K      = 3,   // convolution kernel is K x K
    parameter POOL   = 2    // pooling window is POOL x POOL
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 en,
    input  wire [N-1:0]         activation_in,
    input  wire [(K*K*N)-1:0]   weight,
    input  wire [1:0]           pool_type,
    output reg  [N-1:0]         data_out,
    output reg                  valid_out,
    output reg                  done
);

    localparam integer CONV_DIM   = IMG - K + 1;
    localparam integer CONV_COUNT = CONV_DIM * CONV_DIM;
    localparam integer POOL_DIM   = CONV_DIM / POOL;
    localparam integer POOL_COUNT = POOL_DIM * POOL_DIM;
    localparam integer IMG_COUNT  = IMG * IMG;

    localparam [2:0] ST_IDLE   = 3'd0,
                      ST_LOAD   = 3'd1,
                      ST_CONV   = 3'd2,
                      ST_POOL   = 3'd3,
                      ST_STREAM = 3'd4,
                      ST_DONE   = 3'd5;

    reg [2:0] state;

    reg [N-1:0] img_buf [0:IMG_COUNT-1];
    reg [(K*K*N)-1:0] weight_reg;
    reg [1:0] pool_type_reg;
    reg [$clog2(IMG_COUNT)-1:0] load_idx;

    reg [N-1:0] relu_arr [0:CONV_COUNT-1];
    reg [N-1:0] pool_arr [0:POOL_COUNT-1];
    reg [$clog2(POOL_COUNT)-1:0] stream_idx;

    integer li;

    // ---- Parallel convolution + quantize + ReLU for every window position ----
    wire [N-1:0] relu_comb [0:CONV_COUNT-1];

    genvar gp, gkr, gkc;
    generate
        for (gp = 0; gp < CONV_COUNT; gp = gp + 1) begin : g_pos
            localparam integer R = gp / CONV_DIM;
            localparam integer C = gp % CONV_DIM;

            wire [K*K*N-1:0] window_flat;
            for (gkr = 0; gkr < K; gkr = gkr + 1) begin : g_row
                for (gkc = 0; gkc < K; gkc = gkc + 1) begin : g_col
                    assign window_flat[(gkr*K+gkc)*N +: N] = img_buf[(R+gkr)*IMG + (C+gkc)];
                end
            end

            wire [N-1:0] conv_raw;
            mac_window #(.N(N), .Q(Q), .K(K)) u_mac (
                .window_flat (window_flat),
                .kernel_flat (weight_reg),
                .result      (conv_raw)
            );

            quant_relu #(.N(N), .QSHIFT(QSHIFT)) u_qr (
                .din  (conv_raw),
                .dout (relu_comb[gp])
            );
        end
    endgenerate

    // ---- Pooling for every POOLxPOOL block over the conv grid ----
    wire [N-1:0] pool_comb [0:POOL_COUNT-1];

    genvar gq;
    generate
        for (gq = 0; gq < POOL_COUNT; gq = gq + 1) begin : g_pool
            localparam integer PR = gq / POOL_DIM;
            localparam integer PC = gq % POOL_DIM;
            localparam integer BASE_R = PR * POOL;
            localparam integer BASE_C = PC * POOL;

            pool_unit #(.N(N)) u_pool (
                .a (relu_arr[(BASE_R+0)*CONV_DIM + (BASE_C+0)]),
                .b (relu_arr[(BASE_R+0)*CONV_DIM + (BASE_C+1)]),
                .c (relu_arr[(BASE_R+1)*CONV_DIM + (BASE_C+0)]),
                .d (relu_arr[(BASE_R+1)*CONV_DIM + (BASE_C+1)]),
                .pool_type (pool_type_reg),
                .result    (pool_comb[gq])
            );
        end
    endgenerate

    // ---- Control FSM ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= ST_IDLE;
            load_idx      <= 0;
            stream_idx    <= 0;
            weight_reg    <= 0;
            pool_type_reg <= 0;
            data_out      <= 0;
            valid_out     <= 0;
            done          <= 0;
            for (li = 0; li < IMG_COUNT; li = li + 1)
                img_buf[li] <= 0;
        end else begin
            valid_out <= 1'b0;
            case (state)
                ST_IDLE: begin
                    done <= 1'b0;
                    if (en) begin
                        weight_reg    <= weight;
                        pool_type_reg <= pool_type;
                        load_idx      <= 0;
                        state         <= ST_LOAD;
                    end
                end

                ST_LOAD: begin
                    img_buf[load_idx] <= activation_in;
                    if (load_idx == IMG_COUNT-1) begin
                        state <= ST_CONV;
                    end else begin
                        load_idx <= load_idx + 1'b1;
                    end
                end

                ST_CONV: begin
                    for (li = 0; li < CONV_COUNT; li = li + 1)
                        relu_arr[li] <= relu_comb[li];
                    state <= ST_POOL;
                end

                ST_POOL: begin
                    for (li = 0; li < POOL_COUNT; li = li + 1)
                        pool_arr[li] <= pool_comb[li];
                    stream_idx <= 0;
                    state <= ST_STREAM;
                end

                ST_STREAM: begin
                    data_out  <= pool_arr[stream_idx];
                    valid_out <= 1'b1;
                    if (stream_idx == POOL_COUNT-1) begin
                        state <= ST_DONE;
                    end else begin
                        stream_idx <= stream_idx + 1'b1;
                    end
                end

                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
