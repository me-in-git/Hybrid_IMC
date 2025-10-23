// controller_hybrid.v
module controller_hybrid (
    input wire clk,
    input wire rst_n,
    input wire start,
    output reg done,
    
    output reg tile_start,
    input wire tile_done,
    input wire [15:0] zero_ops_skipped,
    input wire [15:0] total_ops_executed,
    
    output reg dram_rd_en,
    output reg [31:0] dram_rd_addr,
    output reg dram_wr_en,
    output reg [31:0] dram_wr_addr,
    output reg accumulate_en,
    input wire overflow_detected,
    
    output reg load_weights,
    output reg [2:0] weight_set,
    output reg [1:0] precision_mode,
    output reg sparsity_optimize_en
);

reg [3:0] state;
localparam S_IDLE=0, S_LOAD=1, S_START_TILE=2, S_WAIT_TILE=3, S_WRITE_OUTPUT=4, S_DONE=5;

reg [31:0] overflow_count;
reg [31:0] total_sparsity_ratio;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state <= S_IDLE;
        precision_mode <= 2'b10;
        sparsity_optimize_en <= 1;
        overflow_count <= 0;
        done <= 0;
    end else begin
        case(state)
            S_IDLE: if(start) state <= S_LOAD;
            S_LOAD: begin
                load_weights <= 1;
                weight_set <= 0;
                state <= S_START_TILE;
            end
            S_START_TILE: begin
                tile_start <= 1;
                state <= S_WAIT_TILE;
            end
            S_WAIT_TILE: begin
                tile_start <= 0;
                if(tile_done) begin
                    // Adapt precision based on overflows
                    if(overflow_detected) overflow_count <= overflow_count + 1;
                    if(overflow_count > 100) precision_mode <= 2'b01; // 16-bit
                    total_sparsity_ratio <= (zero_ops_skipped*100)/(zero_ops_skipped+total_ops_executed);
                    if(total_sparsity_ratio > 80) sparsity_optimize_en <= 1;
                    state <= S_WRITE_OUTPUT;
                end
            end
            S_WRITE_OUTPUT: begin
                accumulate_en <= 1;
                dram_wr_en <= 1;
                dram_wr_addr <= 0;
                state <= S_DONE;
            end
            S_DONE: begin
                done <= 1;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
