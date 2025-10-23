// dram_controller_hybrid.v - DRAM with accumulation / IMC
module dram_controller_hybrid #(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 16
)(
    input wire clk,
    input wire rst_n,
    
    input wire cmd_valid,
    input wire cmd_type, // 0=read,1=write
    input wire [ADDR_WIDTH-1:0] cmd_addr,
    input wire [ACC_WIDTH-1:0] write_data,
    input wire accumulate_en,
    output reg [DATA_WIDTH-1:0] read_data,
    output reg read_valid,
    output reg overflow_detected
);

reg [DATA_WIDTH-1:0] dram_storage [0:65535];
reg [ACC_WIDTH-1:0] temp_accum;
reg overflow_flag;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        read_valid <= 0;
        overflow_detected <= 0;
        overflow_flag <= 0;
    end else if(cmd_valid) begin
        if(cmd_type) begin // WRITE
            if(accumulate_en) begin
                // Digital accumulation (simulate DRAM compute)
                temp_accum = { {8{dram_storage[cmd_addr][7]}}, dram_storage[cmd_addr] } + write_data;
                if(temp_accum > 127) begin
                    dram_storage[cmd_addr] <= 127;
                    overflow_flag <= 1;
                end else if(temp_accum < -128) begin
                    dram_storage[cmd_addr] <= 8'd128; // -128
                    overflow_flag <= 1;
                end else begin
                    dram_storage[cmd_addr] <= temp_accum[7:0];
                    overflow_flag <= 0;
                end
                overflow_detected <= overflow_flag;
            end else begin
                dram_storage[cmd_addr] <= write_data[7:0];
            end
        end else begin // READ
            read_data <= dram_storage[cmd_addr];
            read_valid <= 1;
        end
    end else begin
        read_valid <= 0;
        overflow_detected <= 0;
    end
end

// ====================================================
// Analog-style DRAM compute (commented out for now)
// ====================================================
/*
always @(posedge clk) begin
    // Imagine multi-row activation
    // reg [ACC_WIDTH-1:0] analog_accum;
    // analog_accum = bitline_charge(row1 + row2 + ... + rowN);
    // dram_storage[cmd_addr] <= saturate(analog_accum);
end
*/

endmodule
