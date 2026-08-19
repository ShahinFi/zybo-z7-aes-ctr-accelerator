`timescale 1 ns / 1 ps

module zybo_accel_ctrl_slave_lite_v1_0_S00_AXI #
(
    // Width of S_AXI data bus
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    // Width of S_AXI address bus
    parameter integer C_S_AXI_ADDR_WIDTH = 6
)
(
    // AES-CTR control/status ports
    output wire         aes_ctr_start,
    output wire [127:0] aes_key_out,
    output wire [95:0]  aes_nonce_out,
    output wire [31:0]  aes_initial_counter_out,
    input  wire         aes_ctr_idle,

    // Global Clock Signal
    input wire  S_AXI_ACLK,
    // Global Reset Signal. This Signal is Active LOW
    input wire  S_AXI_ARESETN,
    // Write address
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
    input wire [2 : 0] S_AXI_AWPROT,
    input wire  S_AXI_AWVALID,
    output wire  S_AXI_AWREADY,
    // Write data
    input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    input wire  S_AXI_WVALID,
    output wire  S_AXI_WREADY,
    output wire [1 : 0] S_AXI_BRESP,
    output wire  S_AXI_BVALID,
    input wire  S_AXI_BREADY,
    // Read address
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
    input wire [2 : 0] S_AXI_ARPROT,
    input wire  S_AXI_ARVALID,
    output wire  S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
    output wire [1 : 0] S_AXI_RRESP,
    output wire  S_AXI_RVALID,
    input wire  S_AXI_RREADY
);

    // AXI4-Lite signals
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_awaddr;
    reg axi_awready;
    reg axi_wready;
    reg [1 : 0] axi_bresp;
    reg axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_araddr;
    reg axi_arready;
    reg [1 : 0] axi_rresp;
    reg axi_rvalid;

    localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
    localparam integer OPT_MEM_ADDR_BITS = 3;

    localparam [C_S_AXI_DATA_WIDTH-1:0] VERSION_VALUE = 32'h0001_0000;

    // Register map:
    // 0x00 VERSION, read-only
    // 0x04 SCRATCH
    // 0x08 AES_CONTROL, write bit 0 = one-clock AES start pulse
    // 0x0C AES_STATUS, read-only: bit 0 idle, bit 1 busy
    // 0x10 AES_KEY_0, key[127:96]
    // 0x14 AES_KEY_1, key[95:64]
    // 0x18 AES_KEY_2, key[63:32]
    // 0x1C AES_KEY_3, key[31:0]
    // 0x20 AES_NONCE_0, nonce[95:64]
    // 0x24 AES_NONCE_1, nonce[63:32]
    // 0x28 AES_NONCE_2, nonce[31:0]
    // 0x2C AES_INITIAL_COUNTER

    reg [31:0] scratch_reg;
    reg [31:0] aes_key_0_reg;
    reg [31:0] aes_key_1_reg;
    reg [31:0] aes_key_2_reg;
    reg [31:0] aes_key_3_reg;
    reg [31:0] aes_nonce_0_reg;
    reg [31:0] aes_nonce_1_reg;
    reg [31:0] aes_nonce_2_reg;
    reg [31:0] aes_initial_counter_reg;
    reg        aes_ctr_start_reg;

    integer byte_index;

    wire [3:0] write_addr_sel;
    wire [3:0] read_addr_sel;

    assign write_addr_sel = (S_AXI_AWVALID) ?
                            S_AXI_AWADDR[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] :
                            axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];

    assign read_addr_sel = axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    assign aes_ctr_start = aes_ctr_start_reg;
    assign aes_key_out = {
        aes_key_0_reg,
        aes_key_1_reg,
        aes_key_2_reg,
        aes_key_3_reg
    };
    assign aes_nonce_out = {
        aes_nonce_0_reg,
        aes_nonce_1_reg,
        aes_nonce_2_reg
    };
    assign aes_initial_counter_out = aes_initial_counter_reg;

    // State machine variables
    reg [1:0] state_write;
    reg [1:0] state_read;

    localparam Idle  = 2'b00,
               Raddr = 2'b10,
               Rdata = 2'b11,
               Waddr = 2'b10,
               Wdata = 2'b11;

    // Implement Write state machine
    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
            axi_awaddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            state_write <= Idle;
        end
        else
        begin
            case (state_write)
                Idle:
                begin
                    axi_awready <= 1'b1;
                    axi_wready  <= 1'b1;
                    state_write <= Waddr;
                end

                Waddr:
                begin
                    if (S_AXI_AWVALID && S_AXI_AWREADY)
                    begin
                        axi_awaddr <= S_AXI_AWADDR;
                        if (S_AXI_WVALID)
                        begin
                            axi_awready <= 1'b1;
                            state_write <= Waddr;
                            axi_bvalid  <= 1'b1;
                        end
                        else
                        begin
                            axi_awready <= 1'b0;
                            state_write <= Wdata;
                            if (S_AXI_BREADY && axi_bvalid)
                                axi_bvalid <= 1'b0;
                        end
                    end
                    else
                    begin
                        state_write <= state_write;
                        if (S_AXI_BREADY && axi_bvalid)
                            axi_bvalid <= 1'b0;
                    end
                end

                Wdata:
                begin
                    if (S_AXI_WVALID)
                    begin
                        state_write <= Waddr;
                        axi_bvalid  <= 1'b1;
                        axi_awready <= 1'b1;
                    end
                    else
                    begin
                        state_write <= state_write;
                        if (S_AXI_BREADY && axi_bvalid)
                            axi_bvalid <= 1'b0;
                    end
                end

                default:
                begin
                    state_write <= Idle;
                end
            endcase
        end
    end

    // Implement memory mapped register select and write logic generation.
    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            scratch_reg             <= 32'h0000_0000;
            aes_key_0_reg           <= 32'h0000_0000;
            aes_key_1_reg           <= 32'h0000_0000;
            aes_key_2_reg           <= 32'h0000_0000;
            aes_key_3_reg           <= 32'h0000_0000;
            aes_nonce_0_reg         <= 32'h0000_0000;
            aes_nonce_1_reg         <= 32'h0000_0000;
            aes_nonce_2_reg         <= 32'h0000_0000;
            aes_initial_counter_reg <= 32'h0000_0000;
            aes_ctr_start_reg       <= 1'b0;
        end
        else
        begin
            aes_ctr_start_reg <= 1'b0;

            if (S_AXI_WVALID)
            begin
                case (write_addr_sel)
                    4'h0:
                    begin
                        // VERSION is read-only.
                    end

                    4'h1:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                scratch_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'h2:
                    begin
                        if (S_AXI_WSTRB[0] && S_AXI_WDATA[0])
                            aes_ctr_start_reg <= 1'b1;
                    end

                    4'h3:
                    begin
                        // AES_STATUS is read-only.
                    end

                    4'h4:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_key_0_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'h5:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_key_1_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'h6:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_key_2_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'h7:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_key_3_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'h8:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_nonce_0_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'h9:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_nonce_1_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'hA:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_nonce_2_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    4'hB:
                    begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1)
                            if (S_AXI_WSTRB[byte_index])
                                aes_initial_counter_reg[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                    end

                    default:
                    begin
                    end
                endcase
            end
        end
    end

    // Implement read state machine
    always @(posedge S_AXI_ACLK)
    begin
        if (S_AXI_ARESETN == 1'b0)
        begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b00;
            axi_araddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            state_read  <= Idle;
        end
        else
        begin
            case (state_read)
                Idle:
                begin
                    state_read  <= Raddr;
                    axi_arready <= 1'b1;
                end

                Raddr:
                begin
                    if (S_AXI_ARVALID && S_AXI_ARREADY)
                    begin
                        state_read  <= Rdata;
                        axi_araddr  <= S_AXI_ARADDR;
                        axi_rvalid  <= 1'b1;
                        axi_arready <= 1'b0;
                    end
                    else
                    begin
                        state_read <= state_read;
                    end
                end

                Rdata:
                begin
                    if (S_AXI_RVALID && S_AXI_RREADY)
                    begin
                        axi_rvalid  <= 1'b0;
                        axi_arready <= 1'b1;
                        state_read  <= Raddr;
                    end
                    else
                    begin
                        state_read <= state_read;
                    end
                end

                default:
                begin
                    state_read <= Idle;
                end
            endcase
        end
    end

    // Implement memory mapped register select and read logic generation.
    assign S_AXI_RDATA =
        (read_addr_sel == 4'h0) ? VERSION_VALUE :
        (read_addr_sel == 4'h1) ? scratch_reg :
        (read_addr_sel == 4'h2) ? 32'h0000_0000 :
        (read_addr_sel == 4'h3) ? {30'b0, ~aes_ctr_idle, aes_ctr_idle} :
        (read_addr_sel == 4'h4) ? aes_key_0_reg :
        (read_addr_sel == 4'h5) ? aes_key_1_reg :
        (read_addr_sel == 4'h6) ? aes_key_2_reg :
        (read_addr_sel == 4'h7) ? aes_key_3_reg :
        (read_addr_sel == 4'h8) ? aes_nonce_0_reg :
        (read_addr_sel == 4'h9) ? aes_nonce_1_reg :
        (read_addr_sel == 4'hA) ? aes_nonce_2_reg :
        (read_addr_sel == 4'hB) ? aes_initial_counter_reg :
        32'h0000_0000;

endmodule
