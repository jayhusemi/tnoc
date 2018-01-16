module noc_route_selector
  import  noc_config_pkg::*;
#(
  parameter   noc_config  CONFIG          = NOC_DEFAULT_CONFIG,
  parameter   int         X               = 0,
  parameter   int         Y               = 0,
  parameter   bit [4:0]   AVAILABLE_PORTS = 5'b11111,
  localparam  int         CHANNELS        = CONFIG.virtual_channels
)(
  input logic                   clk,
  input logic                   rst_n,
  noc_flit_if.target            flit_in_if[CHANNELS],
  noc_flit_if.initiator         flit_out_if[5],
  noc_port_control_if.requester port_control_if[5]
);
  localparam  int SIZE_X  = CONFIG.size_x;
  localparam  int SIZE_Y  = CONFIG.size_y;

  `include  "noc_packet.svh"
  `include  "noc_flit.svh"
  `include  "noc_flit_utils.svh"

  typedef enum logic [4:0] {
    ROUTE_X_PLUS  = 5'b00001,
    ROUTE_X_MINUS = 5'b00010,
    ROUTE_Y_PLUS  = 5'b00100,
    ROUTE_Y_MINUS = 5'b01000,
    ROUTE_LOCAL   = 5'b10000,
    ROUTE_NA      = 5'b00000
  } e_route;

  function automatic e_route select_route(input noc_flit flit);
    noc_common_header header  = get_common_header(flit);
    noc_location_id   id      = header.destination_id;
    case (1'b1)
      (id.x > X) && AVAILABLE_PORTS[0]: return ROUTE_X_PLUS;
      (id.x < X) && AVAILABLE_PORTS[1]: return ROUTE_X_MINUS;
      (id.y > Y) && AVAILABLE_PORTS[2]: return ROUTE_Y_PLUS;
      (id.y < Y) && AVAILABLE_PORTS[3]: return ROUTE_Y_MINUS;
      default:                          return ROUTE_LOCAL;
    endcase
  endfunction

  function automatic noc_flit set_invalid_destination_flag(input noc_flit flit);
    noc_common_header header  = get_common_header(flit);
    noc_location_id   id      = header.destination_id;
    if (is_header_flit(flit) && ((id.x >= SIZE_X) || (id.y >= SIZE_Y))) begin
      header.invalid_destination  = '1;
      return set_common_header(flit, header);
    end
    else begin
      return flit;
    end
  endfunction

//--------------------------------------------------------------
//  Route Control
//--------------------------------------------------------------
  logic [4:0]           port_grant[CHANNELS];
  logic [CHANNELS-1:0]  vc_grant[5];

  generate for (genvar i = 0;i < CHANNELS;++i) begin : g_route_control
    e_route route;
    assign  route = select_route(flit_in_if[i].flit);

    for (genvar j = 0;j < 5;++j) begin
      if (AVAILABLE_PORTS[j]) begin
        assign  port_control_if[j].port_request[i]  = (
          flit_in_if[i].valid && is_header_flit(flit_in_if[i].flit) && route[j]
        ) ? '1 : '0;
        assign  port_control_if[j].port_free[i]     = (
          flit_in_if[i].valid && flit_in_if[i].ready && is_tail_flit(flit_in_if[i].flit)
        ) ? '1 : '0;
        assign  port_grant[i][j]                    = port_control_if[j].port_grant[i];
        assign  port_control_if[j].vc_request[i]    = flit_in_if[i].valid;
        assign  port_control_if[j].vc_free[i]       = flit_in_if[i].ready;
        assign  vc_grant[j][i]                      = port_control_if[j].vc_grant[i];
      end
      else begin
        assign  port_control_if[j].port_request[i]  = '0;
        assign  port_control_if[j].port_free[i]     = '0;
        assign  port_control_if[j].vc_request[i]    = '0;
        assign  port_grant[i][j]                    = '0;
        assign  port_control_if[j].vc_free[i]       = '0;
        assign  vc_grant[j][i]                      = '0;
      end
    end
  end endgenerate

//--------------------------------------------------------------
//  Routing
//--------------------------------------------------------------
  noc_flit_if #(CONFIG, 1)  flit_routed_if[5*CHANNELS]();

  generate for (genvar i = 0;i < CHANNELS;++i) begin : g_routing
    noc_flit_if #(CONFIG, 1)  flit_demux_in_if();
    noc_flit_if #(CONFIG, 1)  flit_demux_out_if[5]();

    assign  flit_demux_in_if.valid      = flit_in_if[i].valid;
    assign  flit_in_if[i].ready         = flit_demux_in_if.ready;
    assign  flit_demux_in_if.flit       = set_invalid_destination_flag(flit_in_if[i].flit);
    assign  flit_in_if[i].vc_available  = flit_demux_in_if.vc_available;

    noc_flit_if_demux #(
      .CONFIG   (CONFIG ),
      .CHANNELS (1      ),
      .ENTRIES  (5      )
    ) u_demux (
      .i_select     (port_grant[i]      ),
      .flit_in_if   (flit_demux_in_if   ),
      .flit_out_if  (flit_demux_out_if  )
    );

    for (genvar j = 0;j < 5;++j) begin : g_renaming
      noc_flit_if_renamer u_renamer (flit_demux_out_if[j], flit_routed_if[CHANNELS*j+i]);
    end
  end endgenerate

//--------------------------------------------------------------
//  VC Merging
//--------------------------------------------------------------
  generate for (genvar i = 0;i < 5;++i) begin : g_vc_merging
    if (AVAILABLE_PORTS[i]) begin : g
      noc_flit_if #(CONFIG, 1)  flit_vc_if[CHANNELS]();

      for (genvar j = 0;j < CHANNELS;++j) begin : g_renaming
        noc_flit_if_renamer u_renamer (flit_routed_if[CHANNELS*i+j], flit_vc_if[j]);
      end

      noc_vc_merger #(CONFIG) u_vc_merger (
        .clk          (clk            ),
        .rst_n        (rst_n          ),
        .i_vc_grant   (vc_grant[i]    ),
        .flit_in_if   (flit_vc_if     ),
        .flit_out_if  (flit_out_if[i] )
      );
    end
    else begin : g_dummy
      for (genvar j = 0;j < CHANNELS;++j) begin
        assign  flit_routed_if[CHANNELS*i+j].ready        = '0;
        assign  flit_routed_if[CHANNELS*i+j].vc_available = '0;
      end

      assign  flit_out_if[i].valid  = '0;
      assign  flit_out_if[i].flit   = '0;
    end
  end endgenerate
endmodule