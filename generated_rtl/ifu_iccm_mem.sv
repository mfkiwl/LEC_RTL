//********************************************************************************
// SPDX-License-Identifier: Apache-2.0
// Copyright 2020 Western Digital Corporation or it's affiliates.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//********************************************************************************

//********************************************************************************
// Icache closely coupled memory --- ICCM
//********************************************************************************

module ifu_iccm_mem/*
#(
   parameter ICCM_BITS,
   parameter ICCM_BANK_INDEX_LO,
   parameter ICCM_INDEX_BITS,
   parameter ICCM_BANK_HI,
   parameter ICCM_NUM_BANKS,
   parameter ICCM_BANK_BITS )*/
   `include "parameter.sv"
   (
   input logic                                        clk,
   input logic                                        rst_l,
   input logic                                        clk_override,

   input logic                                        iccm_wren,
   input logic                                        iccm_rden,
   input logic [ICCM_BITS-1:1]                     iccm_rw_addr,
   input logic                                        iccm_buf_correct_ecc,                // ICCM is doing a single bit error correct cycle
   input logic                                        iccm_correction_state,               // We are under a correction - This is needed to guard replacements when hit
   input logic [2:0]                                  iccm_wr_size,
   input logic [77:0]                                 iccm_wr_data,


   output logic [63:0]                                iccm_rd_data,
   output logic [77:0]                                iccm_rd_data_ecc,
   input  logic                                       scan_mode

);


   logic [ICCM_NUM_BANKS-1:0]                                                wren_bank;
   logic [ICCM_NUM_BANKS-1:0]                                                rden_bank;
   logic [ICCM_NUM_BANKS-1:0]                                                iccm_clken;
   logic [ICCM_NUM_BANKS-1:0] [ICCM_BITS-1:ICCM_BANK_INDEX_LO] addr_bank;

   logic [ICCM_NUM_BANKS-1:0] [38:0]  iccm_bank_dout, iccm_bank_dout_fn;
   logic [ICCM_NUM_BANKS-1:0] [38:0]  iccm_bank_wr_data;
   logic [ICCM_BITS-1:1]              addr_bank_inc;
   logic [ICCM_BANK_HI : 2]           iccm_rd_addr_hi_q;
   logic [ICCM_BANK_HI : 1]           iccm_rd_addr_lo_q;
   logic             [63:0]              iccm_rd_data_pre;
   logic             [63:0]              iccm_data;
   logic [1:0]                           addr_incr;
   logic [ICCM_NUM_BANKS-1:0] [38:0]  iccm_bank_wr_data_vec;

   // logic to handle hard persisten faults
   logic [1:0] [ICCM_BITS-1:2]        redundant_address;
   logic [1:0] [38:0]                    redundant_data;
   logic [1:0]                           redundant_valid;
   logic [ICCM_NUM_BANKS-1:0]         sel_red1, sel_red0, sel_red1_q, sel_red0_q;


   logic [38:0]                          redundant_data0_in, redundant_data1_in;
   logic                                 redundant_lru, redundant_lru_in, redundant_lru_en;
   logic                                 redundant_data0_en;
   logic                                 redundant_data1_en;
   logic                                 r0_addr_en, r1_addr_en;

   assign addr_incr[1:0]                    = (iccm_wr_size[1:0] == 2'b11) ?  2'b10: 2'b01;
   assign addr_bank_inc[ICCM_BITS-1 : 1] = iccm_rw_addr[ICCM_BITS-1 : 1] + addr_incr[1:0];

   for (genvar i=0; i<32'(ICCM_NUM_BANKS)/2; i++) begin: mem_bank_data
      assign iccm_bank_wr_data_vec[(2*i)]   = iccm_wr_data[38:0];
      assign iccm_bank_wr_data_vec[(2*i)+1] = iccm_wr_data[77:39];
   end

   for (genvar i=0; i<32'(ICCM_NUM_BANKS); i++) begin: mem_bank
      assign wren_bank[i]         = iccm_wren & ((iccm_rw_addr[ICCM_BANK_HI:2] == i) | (addr_bank_inc[ICCM_BANK_HI:2] == i));
      assign iccm_bank_wr_data[i] = iccm_bank_wr_data_vec[i];
      assign rden_bank[i]         = iccm_rden & ( (iccm_rw_addr[ICCM_BANK_HI:2] == i) | (addr_bank_inc[ICCM_BANK_HI:2] == i));
      assign iccm_clken[i]        =  wren_bank[i] | rden_bank[i] | clk_override;
      assign addr_bank[i][ICCM_BITS-1 : ICCM_BANK_INDEX_LO] = wren_bank[i] ? iccm_rw_addr[ICCM_BITS-1 : ICCM_BANK_INDEX_LO] :
                                                                                      ((addr_bank_inc[ICCM_BANK_HI:2] == i) ?
                                                                                                    addr_bank_inc[ICCM_BITS-1 : ICCM_BANK_INDEX_LO] :
                                                                                                    iccm_rw_addr[ICCM_BITS-1 : ICCM_BANK_INDEX_LO]);
 `ifdef VERILATOR

    el2_ram #(.depth(1<<ICCM_INDEX_BITS), .width(39)) iccm_bank (
                                     // Primary ports
                                     .ME(iccm_clken[i]),
                                     .CLK(clk),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
 `else

     if (ICCM_INDEX_BITS == 6 ) begin : iccm
               ram_64x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm

   else if (ICCM_INDEX_BITS == 7 ) begin : iccm
               ram_128x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm

     else if (ICCM_INDEX_BITS == 8 ) begin : iccm
               ram_256x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
     else if (ICCM_INDEX_BITS == 9 ) begin : iccm
               ram_512x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
     else if (ICCM_INDEX_BITS == 10 ) begin : iccm
               ram_1024x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
     else if (ICCM_INDEX_BITS == 11 ) begin : iccm
               ram_2048x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
     else if (ICCM_INDEX_BITS == 12 ) begin : iccm
               ram_4096x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
     else if (ICCM_INDEX_BITS == 13 ) begin : iccm
               ram_8192x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
     else if (ICCM_INDEX_BITS == 14 ) begin : iccm
               ram_16384x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
     else begin : iccm
               ram_32768x39 iccm_bank (
                                     // Primary ports
                                     .CLK(clk),
                                     .ME(iccm_clken[i]),
                                     .WE(wren_bank[i]),
                                     .ADR(addr_bank[i]),
                                     .D(iccm_bank_wr_data[i][38:0]),
                                     .Q(iccm_bank_dout[i][38:0])

                                      );
     end // block: iccm
`endif

   // match the redundant rows
   assign sel_red1[i]  = (redundant_valid[1]  & (((iccm_rw_addr[ICCM_BITS-1:2] == redundant_address[1][ICCM_BITS-1:2]) & (iccm_rw_addr[3:2] == i)) |
                                                 ((addr_bank_inc[ICCM_BITS-1:2]== redundant_address[1][ICCM_BITS-1:2]) & (addr_bank_inc[3:2] == i))));

   assign sel_red0[i]  = (redundant_valid[0]  & (((iccm_rw_addr[ICCM_BITS-1:2] == redundant_address[0][ICCM_BITS-1:2]) & (iccm_rw_addr[3:2] == i)) |
                                                 ((addr_bank_inc[ICCM_BITS-1:2]== redundant_address[0][ICCM_BITS-1:2]) & (addr_bank_inc[3:2] == i))));

   rvdff #(1) selred0  (.*,
                   .clk(clk),
                   .din(sel_red0[i]),
                   .dout(sel_red0_q[i]));

   rvdff #(1) selred1  (.*,
                   .clk(clk),
                   .din(sel_red1[i]),
                   .dout(sel_red1_q[i]));


  // muxing out the memory data with the redundant data if the address matches
    assign iccm_bank_dout_fn[i][38:0] = ({39{sel_red1_q[i]}}                         & redundant_data[1][38:0]) |
                                        ({39{sel_red0_q[i]}}                         & redundant_data[0][38:0]) |
                                        ({39{~sel_red0_q[i] & ~sel_red1_q[i]}}       & iccm_bank_dout[i][38:0]);


  end : mem_bank
// This section does the redundancy for tolerating single bit errors
// 2x 39 bit data values with address[hi:2] and a valid bit is needed to CAM and sub out the reads/writes to the particular locations
// Also a LRU flop is kept to decide which of the redundant element to replace.
   assign r0_addr_en              = ~redundant_lru & iccm_buf_correct_ecc;
   assign r1_addr_en              = redundant_lru  & iccm_buf_correct_ecc;
   assign redundant_lru_en         = iccm_buf_correct_ecc | (((|sel_red0[ICCM_NUM_BANKS-1:0]) | (|sel_red1[ICCM_NUM_BANKS-1:0])) & iccm_rden & iccm_correction_state);
   assign redundant_lru_in        = iccm_buf_correct_ecc ? ~redundant_lru : (|sel_red0[ICCM_NUM_BANKS-1:0]) ? 1'b1 : 1'b0;

   rvdffs #() red_lru  (.*,                               // LRU flop for the redundant replacements
                   .clk(clk),
                   .en(redundant_lru_en),
                   .din(redundant_lru_in),
                   .dout(redundant_lru));

    rvdffs #(ICCM_BITS-2) r0_address  (.*,                 // Redundant Row 0 address
                   .clk(clk),
                   .en(r0_addr_en),
                   .din(iccm_rw_addr[ICCM_BITS-1:2]),
                   .dout(redundant_address[0][ICCM_BITS-1:2]));

   rvdffs #(ICCM_BITS-2) r1_address  (.*,                   // Redundant Row 0 address
                   .clk(clk),
                   .en(r1_addr_en),
                   .din(iccm_rw_addr[ICCM_BITS-1:2]),
                   .dout(redundant_address[1][ICCM_BITS-1:2]));

    rvdffs #(1) r0_valid  (.*,
                   .clk(clk),                                  // Redundant Row 0 Valid
                   .en(r0_addr_en),
                   .din(1'b1),
                   .dout(redundant_valid[0]));

   rvdffs #(1) r1_valid  (.*,                                   // Redundant Row 1 Valid
                   .clk(clk),
                   .en(r1_addr_en),
                   .din(1'b1),
                   .dout(redundant_valid[1]));



   // We will have to update the Redundant copies in addition to the memory on subsequent writes to this memory location.
   // The data gets updated on : 1) correction cycle, 2) Future writes - this could be W writes from DMA ( match up till addr[2]) or DW writes ( match till address[3])
   // The data to pick also depends on the current address[2], size and the addr[2] stored in the address field of the redundant flop. Correction cycle is always W write and the data is splat on both legs, so choosing lower Word

    assign redundant_data0_en      = ((iccm_rw_addr[ICCM_BITS-1:3] == redundant_address[0][ICCM_BITS-1:3]) & ((iccm_rw_addr[2] == redundant_address[0][2]) | (iccm_wr_size[1:0] == 2'b11)) & redundant_valid[0] & iccm_wren) |
                                      (~redundant_lru & iccm_buf_correct_ecc);

    assign redundant_data0_in[38:0] = (((iccm_rw_addr[2] == redundant_address[0][2]) & iccm_rw_addr[2]) | (redundant_address[0][2] & (iccm_wr_size[1:0] == 2'b11))) ? iccm_wr_data[77:39]  : iccm_wr_data[38:0];

    rvdffs #(39) r0_data  (.*,                                 // Redundant Row 1 data
                   .clk(clk),
                   .en(redundant_data0_en),
                   .din(redundant_data0_in[38:0]),
                   .dout(redundant_data[0][38:0]));

   assign redundant_data1_en      =  ((iccm_rw_addr[ICCM_BITS-1:3] == redundant_address[1][ICCM_BITS-1:3]) & ((iccm_rw_addr[2] == redundant_address[1][2]) | (iccm_wr_size[1:0] == 2'b11)) & redundant_valid[1] & iccm_wren) |
                                     (redundant_lru & iccm_buf_correct_ecc);

   assign redundant_data1_in[38:0] = (((iccm_rw_addr[2] == redundant_address[1][2]) & iccm_rw_addr[2]) | (redundant_address[1][2] & (iccm_wr_size[1:0] == 2'b11))) ? iccm_wr_data[77:39]  : iccm_wr_data[38:0];

    rvdffs #(39) r1_data  (.*,                                  // Redundant Row 1 data
                   .clk(clk),
                   .en(redundant_data1_en),
                   .din(redundant_data1_in[38:0]),
                   .dout(redundant_data[1][38:0]));


   rvdffs  #(ICCM_BANK_HI)   rd_addr_lo_ff (.*, .din(iccm_rw_addr [ICCM_BANK_HI:1]), .dout(iccm_rd_addr_lo_q[ICCM_BANK_HI:1]), .en(1'b1));   // bit 0 of address is always 0
   rvdffs  #(ICCM_BANK_BITS) rd_addr_hi_ff (.*, .din(addr_bank_inc[ICCM_BANK_HI:2]), .dout(iccm_rd_addr_hi_q[ICCM_BANK_HI:2]), .en(1'b1));

   assign iccm_rd_data_pre[63:0] = {iccm_bank_dout_fn[iccm_rd_addr_hi_q][31:0], iccm_bank_dout_fn[iccm_rd_addr_lo_q[ICCM_BANK_HI:2]][31:0]};
   assign iccm_data[63:0]        = 64'({16'b0, (iccm_rd_data_pre[63:0] >> (16*iccm_rd_addr_lo_q[1]))});
   assign iccm_rd_data[63:0]     = {iccm_data[63:0]};
   assign iccm_rd_data_ecc[77:0] = {iccm_bank_dout_fn[iccm_rd_addr_hi_q][38:0], iccm_bank_dout_fn[iccm_rd_addr_lo_q[ICCM_BANK_HI:2]][38:0]};

endmodule // el2_ifu_iccm_mem
