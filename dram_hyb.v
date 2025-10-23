module enhanced_dram_imc_fixed #(
    parameter ADDR_WIDTH = 16,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 16,
    parameter NUM_BANKS  = 4,
    parameter BANK_DEPTH = 16384
)(
    input wire clk,
    input wire rst_n,
    
    input wire cmd_valid,
    input wire [1:0] cmd_type,
    input wire [ADDR_WIDTH-1:0] cmd_addr,
    input wire [ACC_WIDTH-1:0] write_data,
    input wire accumulate_en,
    
    input wire [NUM_BANKS-1:0] bank_activate,
    input wire simultaneous_access,
    
    output reg [DATA_WIDTH-1:0] read_data,
    output reg [ACC_WIDTH-1:0] compute_result,
    output reg read_valid,
    output reg compute_valid,
    output reg overflow_detected,
    
    output reg [15:0] parallel_ops_executed,
    output reg [15:0] dram_energy_used
);

    reg signed [DATA_WIDTH-1:0] bank_memory [0:NUM_BANKS*BANK_DEPTH-1];
    reg signed [ACC_WIDTH-1:0] bank_accumulators [0:NUM_BANKS-1];
    reg [2:0] bank_state [0:NUM_BANKS-1];
    reg bank_valid [0:NUM_BANKS-1];

    integer bank;
    integer i;
    integer t_index;
    reg signed [ACC_WIDTH-1:0] temp_sum;
    reg signed [ACC_WIDTH-1:0] temp_accum;
    integer access_count;
    integer compute_count;
    reg [1:0] target_bank;
    integer addr_low;

    localparam BANK_IDLE = 0, BANK_READ = 1, BANK_COMPUTE = 2;

    // Helper: compute flat index for bank and address
    function integer flat_idx;
        input integer b;
        input integer a;
        begin
            flat_idx = b * BANK_DEPTH + a;
        end
    endfunction

    // Bank controllers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin
                bank_state[bank] <= BANK_IDLE;
                bank_accumulators[bank] <= 0;
                bank_valid[bank] <= 0;
            end
            access_count <= 0;
            compute_count <= 0;
            parallel_ops_executed <= 0;
            dram_energy_used <= 0;
            overflow_detected <= 0;
        end else begin
            for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin
                case (bank_state[bank])
                    BANK_IDLE: begin
                        bank_valid[bank] <= 0;
                        if (bank_activate[bank] && cmd_valid) begin
                            if (cmd_type == 2'b00) begin // READ
                                bank_state[bank] <= BANK_READ;
                                // latch read_data in output stage
                            end else if (cmd_type == 2'b10) begin // COMPUTE
                                bank_state[bank] <= BANK_COMPUTE;
                                temp_sum = 0;
                                // accumulate up to 8 entries (guarded by BANK_DEPTH)
                                for (i = 0; i < 8; i = i + 1) begin
                                    addr_low = cmd_addr + i;
                                    if (addr_low < BANK_DEPTH) begin
                                        temp_sum = temp_sum + bank_memory[ flat_idx(bank, addr_low) ];
                                    end
                                end
                                bank_accumulators[bank] <= temp_sum;
                                compute_count <= compute_count + 1;
                            end
                        end
                    end

                    BANK_READ: begin
                        bank_valid[bank] <= 1;
                        bank_state[bank] <= BANK_IDLE;
                        access_count <= access_count + 1;
                    end

                    BANK_COMPUTE: begin
                        bank_valid[bank] <= 1;
                        bank_state[bank] <= BANK_IDLE;
                        parallel_ops_executed <= parallel_ops_executed + 8;
                    end
                endcase
            end
        end
    end

    // Output combination and energy estimation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_valid <= 0;
            compute_valid <= 0;
            read_data <= 0;
            compute_result <= 0;
            dram_energy_used <= 0;
        end else begin
            read_valid <= 0;
            compute_valid <= 0;
            temp_sum = 0;
            // combine active banks
            for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin
                if (bank_valid[bank]) begin
                    read_valid <= 1;
                    if (cmd_type == 2'b10) compute_valid <= 1;
                    if (simultaneous_access) begin
                        temp_sum = temp_sum + bank_accumulators[bank];
                    end else begin
                        // single-bank return behavior: return bank's memory at cmd_addr low bits
                        read_data <= bank_memory[ flat_idx(bank, cmd_addr % BANK_DEPTH) ];
                        compute_result <= bank_accumulators[bank];
                    end
                end
            end
            if (simultaneous_access) begin
                compute_result <= temp_sum;
                // provide a representative read_data (bank 0)
                read_data <= bank_memory[ flat_idx(0, cmd_addr % BANK_DEPTH) ];
            end
            dram_energy_used <= (access_count * 2) + (compute_count * 5);
        end
    end

    // Write logic (accumulate or overwrite)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            overflow_detected <= 0;
        end else begin
            if (cmd_valid && cmd_type == 2'b01) begin // WRITE
                // split cmd_addr into bank id (top bits) and local addr (low bits)
                target_bank = cmd_addr[ADDR_WIDTH-1:ADDR_WIDTH-2];
                addr_low = cmd_addr[ADDR_WIDTH-3:0];
                t_index = flat_idx(target_bank, addr_low);
                if (accumulate_en) begin
                    temp_accum = bank_memory[t_index] + $signed(write_data);
                    if (temp_accum > 127) begin
                        bank_memory[t_index] <= 127;
                        overflow_detected <= 1;
                    end else if (temp_accum < -128) begin
                        bank_memory[t_index] <= -128;
                        overflow_detected <= 1;
                    end else begin
                        bank_memory[t_index] <= temp_accum[7:0];
                        overflow_detected <= 0;
                    end
                end else begin
                    bank_memory[t_index] <= write_data[7:0];
                    overflow_detected <= 0;
                end
            end
        end
    end

    // Init memory for simulation
    integer b, a;
    initial begin
        for (b = 0; b < NUM_BANKS; b = b + 1) begin
            for (a = 0; a < BANK_DEPTH; a = a + 1) begin
                bank_memory[ flat_idx(b,a) ] = (a + b * 64) & 8'hFF;
            end
        end
    end

endmodule
