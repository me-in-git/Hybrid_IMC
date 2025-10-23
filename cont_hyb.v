// advanced_hybrid_controller_fixed.v
module advanced_hybrid_controller_fixed (
    input wire clk,
    input wire rst_n,
    input wire start,
    output reg done,
    
    output reg tile_start,
    input wire tile_done,
    output reg imc_mode,
    output reg simultaneous_rows,
    output reg [63:0] row_mask,
    
    input wire [15:0] zero_ops_skipped,
    input wire [15:0] total_ops_executed,
    input wire [15:0] imc_energy_savings,
    input wire [7:0] computation_snr,
    
    output reg dram_cmd_valid,
    output reg [1:0] dram_cmd_type,
    output reg [15:0] dram_cmd_addr,
    output reg [15:0] dram_write_data,
    output reg dram_accumulate_en,
    output reg [3:0] dram_bank_activate,
    output reg dram_simultaneous_access,
    
    output reg [1:0] precision_mode,
    output reg sparsity_optimize_en,
    output reg adaptive_imc_en,
    
    output reg [7:0] system_efficiency,
    output reg [15:0] total_energy_saved,
    output reg snr_too_low
);

    // FSM state and counters
    reg [3:0] state;
    reg [31:0] cycle_count;
    reg [15:0] total_skipped;
    reg [15:0] total_executed;
    reg [7:0] average_snr;
    reg [2:0] imc_aggressiveness;

    // Temporaries (module scope for Verilog-2001)
    reg [15:0] temp_sparsity_ratio;
    reg start_prev;

    localparam SNR_THRESHOLD_LOW = 40;
    localparam SNR_THRESHOLD_HIGH = 80;
    localparam SPARSITY_THRESHOLD = 60;

    localparam S_IDLE = 0, S_LOAD = 1, S_ANALYZE = 2, S_IMC_COMPUTE = 3, 
               S_DIGITAL_COMPUTE = 4, S_DRAM_STORE = 5, S_ADAPT = 6, S_DONE = 7;

    // Reset and FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 0;
            precision_mode <= 2'b10;
            sparsity_optimize_en <= 1;
            adaptive_imc_en <= 1;
            imc_aggressiveness <= 3'b100;
            total_energy_saved <= 0;
            system_efficiency <= 0;
            cycle_count <= 0;
            total_skipped <= 0;
            total_executed <= 0;
            average_snr <= 100;
            snr_too_low <= 0;
            start_prev <= 0;
            
            // Initialize outputs
            tile_start <= 0;
            imc_mode <= 0;
            simultaneous_rows <= 0;
            row_mask <= 64'b0;
            dram_cmd_valid <= 0;
            dram_cmd_type <= 0;
            dram_cmd_addr <= 0;
            dram_write_data <= 0;
            dram_accumulate_en <= 0;
            dram_bank_activate <= 0;
            dram_simultaneous_access <= 0;
        end else begin
            start_prev <= start;
            // defaults each cycle
            tile_start <= 0;
            dram_cmd_valid <= 0;
            
            case (state)
                S_IDLE: begin
                    done <= 0;
                    cycle_count <= 0;
                    total_skipped <= 0;
                    total_executed <= 0;
                    average_snr <= 100;
                    if (start) state <= S_LOAD;
                end
                
                S_LOAD: begin
                    dram_cmd_valid <= 1;
                    dram_cmd_type <= 2'b00; // READ
                    dram_cmd_addr <= 0;
                    dram_bank_activate <= 4'b1111;
                    state <= S_ANALYZE;
                end
                
                S_ANALYZE: begin
                    if ((total_skipped + total_executed) != 0)
                        temp_sparsity_ratio = (total_skipped * 100) / (total_skipped + total_executed);
                    else
                        temp_sparsity_ratio = 0;
                    
                    if (adaptive_imc_en) begin
                        if (temp_sparsity_ratio > SPARSITY_THRESHOLD && average_snr > SNR_THRESHOLD_LOW) begin
                            imc_mode <= 1;
                            simultaneous_rows <= 1;
                            row_mask <= 64'hFFFFFFFFFFFFFFFF;
                            imc_aggressiveness <= 3'b111;
                            state <= S_IMC_COMPUTE;
                        end else if (temp_sparsity_ratio > 30 && average_snr > SNR_THRESHOLD_HIGH) begin
                            imc_mode <= 1;
                            simultaneous_rows <= 0;
                            row_mask <= 64'h00000000FFFFFFFF;
                            imc_aggressiveness <= 3'b011;
                            state <= S_IMC_COMPUTE;
                        end else begin
                            imc_mode <= 0;
                            state <= S_DIGITAL_COMPUTE;
                        end
                    end else begin
                        imc_mode <= 1;
                        state <= S_IMC_COMPUTE;
                    end
                    tile_start <= 1;
                end
                
                S_IMC_COMPUTE: begin
                    if (tile_done) begin
                        total_skipped <= total_skipped + zero_ops_skipped;
                        total_executed <= total_executed + total_ops_executed;
                        total_energy_saved <= total_energy_saved + imc_energy_savings;
                        average_snr <= (average_snr + computation_snr) >> 1;
                        
                        snr_too_low <= (computation_snr < SNR_THRESHOLD_LOW);
                        if ((zero_ops_skipped + total_ops_executed) > 0) begin
                            system_efficiency <= (zero_ops_skipped * 100) / (zero_ops_skipped + total_ops_executed);
                        end
                        
                        state <= S_DRAM_STORE;
                    end
                end
                
                S_DIGITAL_COMPUTE: begin
                    if (tile_done) begin
                        total_skipped <= total_skipped + zero_ops_skipped;
                        total_executed <= total_executed + total_ops_executed;
                        if ((zero_ops_skipped + total_ops_executed) > 0) begin
                            system_efficiency <= (zero_ops_skipped * 100) / (zero_ops_skipped + total_ops_executed);
                        end
                        state <= S_DRAM_STORE;
                    end
                end
                
                S_DRAM_STORE: begin
                    dram_cmd_valid <= 1;
                    dram_cmd_type <= 2'b01; // WRITE
                    dram_accumulate_en <= 1;
                    dram_simultaneous_access <= 1;
                    dram_bank_activate <= 4'b1111;
                    state <= S_ADAPT;
                end
                
                S_ADAPT: begin
                    if (snr_too_low) begin
                        if (precision_mode > 0) begin
                            precision_mode <= precision_mode - 1;
                        end else begin
                            adaptive_imc_en <= 0;
                        end
                    end
                    
                    if (cycle_count > 10) begin
                        state <= S_DONE;
                    end else begin
                        state <= S_ANALYZE;
                    end
                    cycle_count <= cycle_count + 1;
                end
                
                S_DONE: begin
                    done <= 1;
                    // Hold DONE until start is released (edge detect)
                    if (!start && start_prev) begin
                        done <= 0;
                        state <= S_IDLE;
                    end
                end
                
            endcase
        end
    end

endmodule
