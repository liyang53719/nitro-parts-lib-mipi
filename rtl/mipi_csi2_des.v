
// TODO fix
/* verilator lint_off CMPCONST */

module mipi_csi2_des
  #(parameter DATA_WIDTH=10, parameter MAX_LANES=3)
  (
   input 	     resetb,
   input         enable,

   input 	     mcp,
   input 	     mcn,
   input [MAX_LANES-1:0] mdp,
   input [MAX_LANES-1:0] mdn,
   input [MAX_LANES-1:0] mdp_lp,
   input [MAX_LANES-1:0] mdn_lp,

   output        img_clk,
   output reg [DATA_WIDTH-1:0] dato,
   output reg        dvo,
   output reg 	     lvo,
   output reg 	     fvo,
`ifdef ARTIX
     input 	  del_ld,
     input [4:0]  del_val_dat,
     input [4:0]  del_val_clk,
   output locked,
   input mmcm_reset,
     input psclk,
`endif
   input [MAX_LANES-1:0]        md_polarity,
   input [2:0]  num_active_lanes,
   input [7:0]   mipi_tx_period
`ifdef MIPI_RAW_OUTPUT
   ,
   input  [1:0]  qmode, // 0 for !mdp_lp && !mdp_lp 1 for all output,2 for shifted phy_data
   output [15:0] raw_mipi_data
`endif
   );

   //wire clk_in_int, clk_div, clk_in_int_buf, clk_in_int_inv, serdes_strobe;
   //
   reg [DATA_WIDTH-1:0] dato0;
   wire                 dvo0;
   reg                  lvo0;
   reg                  fvo0;
   

   wire phy_we;
   wire phy_clk;
   wire [7:0] phy_data;
   wire phy_dvo;

   reg [15:0] wc;
   reg [2:0] state;
   reg dout_en;

`ifdef MIPI_RAW_OUTPUT
   wire [1:0] qstate;
   wire [2:0] sync_pos;
   wire [7:0] qraw;
   reg [7:0]  count0;
   always @(posedge img_clk) begin
      if (!resetb) begin
        count0 <= 0;
      end else begin
        count0 <= (mdp_lp || mdn_lp) ? 0 : count0 + 1;
      end
   end
   assign raw_mipi_data = (qmode == 0) ? { mdp_lp, mdn_lp, phy_we, sync_pos, qstate, qraw } : // for debugging line state/tx period etc
			              (qmode == 1) ? { mdp_lp, mdn_lp, fvo0, lvo0, state, phy_we, phy_data} :  // actual data from bus
                          (qmode == 2) ? { count0, phy_data } :
                          (qmode == 3) ? { wc[7:0], phy_data } :
                          0 ;

`endif

   mipi_phy_des
     #(.MAX_LANES(MAX_LANES))
   mipi_phy_des
     (
      .resetb       (resetb),
      .mcp          (mcp),
      .mcn          (mcn),
      .mdp          (mdp),
      .mdn          (mdn),
      .mdp_lp       (mdp_lp),
      .mdn_lp       (mdn_lp),
      .clk          (phy_clk),
      .we           (phy_we),
      .data         (phy_data),
      .dvo          (phy_dvo),
      .md_polarity  (md_polarity),
`ifdef ARTIX
      .locked(locked),
      .mmcm_reset(mmcm_reset),
      .psclk(psclk),
      .del_ld(del_ld),
      .del_val_dat(del_val_dat),
      .del_val_clk(del_val_clk),
`endif
`ifdef MIPI_RAW_OUTPUT
      .q_out(qraw),
      .state(qstate),
      .sync_pos(sync_pos),
`endif
      .num_active_lanes(num_active_lanes),
      .mipi_tx_period (mipi_tx_period)
   );

   assign img_clk = phy_clk;
   reg resetb_s;
   always @(posedge phy_clk or negedge resetb) begin
      if (!resetb) begin
        resetb_s <= 0;
      end else begin
        resetb_s <= 1;
      end
   end

   localparam ST_IDLE=0, ST_HEADER=1, ST_DATA8=2, ST_DATA10=3, ST_EOT=4;
   localparam ID_FRAME_START=0, ID_FRAME_END=1, ID_LINE_START=2, ID_LINE_END=3;


   reg [1:0] header_cnt; // read the header
   reg [7:0] header[0:3];
   reg [DATA_WIDTH-1:0] data10[0:3];
   reg [2:0] data10pos;
   reg data10start;
   integer i;
   wire [1:0] lsbs[0:3];
   genvar j;
   generate
     for (j=0;j<4;j=j+1) begin : PHY_DATA_BLOCK
         assign lsbs[j] = phy_data[j*2+1:j*2];
		end
   endgenerate
   always @(posedge phy_clk or negedge resetb_s) begin
      if (!resetb_s) begin
          lvo <= 0;
          fvo <= 0;
          lvo0 <= 0;
          fvo0 <= 0;
          dvo <= 0;
          dato0 <= 0;
          dato <= 0;
          header_cnt <= 0;
          data10pos <= 0;
          dout_en <= 0;
          data10start <= 0;
          state <= ST_IDLE;
	 header[0] <= 0;
	 header[1] <= 0;
	 header[2] <= 0;
	 header[3] <= 0;
	 wc <= 0;
	 data10[0] <= 0;
	 data10[1] <= 0;
	 data10[2] <= 0;
	 data10[3] <= 0;


      end else begin // if (!resetb_s)
         fvo <= fvo0;
         lvo <= lvo0;
         dvo <= dvo0;
         dato <= dato0;
         
          if (!enable) begin
            state <= ST_IDLE;
          end else begin
            if (state == ST_IDLE) begin
               if (phy_dvo && phy_we) begin
                  header_cnt <= 1;
                  state <= ST_HEADER;
                  header[0] <= phy_data;
               end
            end else if (state == ST_HEADER) begin
              if (phy_dvo) begin
               if (header_cnt <= 3) begin
                  header[header_cnt] <= phy_data;
                  header_cnt <= header_cnt+1;
               end

               if (header_cnt == 3) begin
                  // collect the header
                  if (header[0][5:0] == ID_FRAME_START) begin
                     fvo0 <= 1;
                     state <= ST_EOT;
                  end else if (header[0][5:0] == ID_FRAME_END) begin
                     fvo0 <= 0;
                     state <= ST_EOT;
                  end else if (header[0][5:0] == 6'h2a) begin
                     wc <= { header[2], header[1] };
                     state <= ST_DATA8;
                  end else if (header[0][5:0] == 6'h2b) begin
                     wc <= { header[2], header[1] };
                     state <= ST_DATA10;
                     data10pos <= 0;
                     data10start <= 1;
                     dout_en <= 0;
                  end else begin
                     state <= ST_EOT; // ignore all other headers right now
                  end

               end
              end
            end else if (state == ST_DATA8) begin
              if (phy_dvo) begin
               if (wc > 0) begin
                  lvo0 <= 1;
                  dout_en <= 1;
                  dato0[DATA_WIDTH-1:DATA_WIDTH-8] <= phy_data;
                  wc <= wc - 1;
               end else begin
                  state <= ST_EOT;
                  lvo0 <= 0;
                  // TODO a frame will also have two bytes for the checksum
               end
              end
            end else if (state == ST_DATA10) begin
              if (phy_dvo) begin
               if (wc > 0) begin
                  lvo0 <= 1;
                  if (wc>0) wc <= wc - 1;
                  // data not valid until we've collected the 5th byte with the
                  // lsbs
                  if (data10pos < 4) begin
                      data10[data10pos[1:0]][9:0] <= {phy_data,2'b0};
                  end
                  if (data10pos == 4) begin
                      data10pos <= 0;
                  end else begin
                      data10pos <= data10pos + 1;
                  end

                  if ((data10start && data10pos==4) || !data10start) begin
                      data10start <= 0;
                      if (data10pos==4) begin
                          // lsbs
                          dout_en <= 0;
                          for ( i=0;i<4;i=i+1) begin
                              data10[i] <= data10[i] | {8'b0, lsbs[i]};
                          end
                      end else begin
                          dout_en <= 1;
                          dato0[9:0] <= data10[data10pos[1:0]];
                      end
                  end
               end else begin
                  if (data10pos<4) begin
                      dato0[9:0] <= data10[data10pos[1:0]];
                      dout_en <= 1;
                      data10pos <= data10pos + 1;
                  end else begin
                      state <= ST_EOT;
                      lvo0 <= 0;
                      dout_en <= 0;
                  end
               end
              end
            end else /* if (state == ST_EOT) */ begin
               // or any other state
               // ignore bytes while phy_we high
               if (!phy_we) begin
                  state <= ST_IDLE;
               end
            end
          end
      end
   end

   assign dvo0 = dout_en & phy_dvo;


endmodule

/* verilator lint_on CMPCONST */
