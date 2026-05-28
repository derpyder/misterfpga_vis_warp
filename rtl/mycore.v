// mycore — Template demo emu, upgraded for vis_warp validation.
//
// Generates 480x360 video timing (4:3 aspect, NTSC=60Hz / PAL=50Hz)
// and emits an 8-bit grayscale video stream. The host Template.sv
// tints to R/G/B via the existing `col` (status[4:3]) option.
//
// 480x360 was picked because it integer-scales exactly to common
// output modes:
//   * 1080p: 360 * 3 = 1080  (3x vertical, NN-clean)
//   * 4K:    360 * 6 = 2160  (6x vertical, NN-clean)
// Width 480 is well within MAX_SRC_W=512 of vis_warp's pixel buffer.
//
// 2026-05-28 upgrade (SPEC-vis_warp-v3.md task #6): added selectable
// test patterns via `pattern[2:0]` input. Pattern 0 keeps the original
// cosine+LFSR animated card; patterns 1..7 are static, deterministic
// shapes designed to make barrel-warp distortion visually obvious.
//
//   0: cosine+LFSR   (animated noise — original behavior)
//   1: grid 16px     (straight lines become curves under warp — primary test)
//   2: vbars 32px    (different stripe spacing for spatial-frequency tests)
//   3: gradient      (continuous left-to-right sweep)
//   4: crosshair     (single-pixel cross at active-area center, white on black)
//   5: gray50        (solid 0x80 — "is anything happening" test)
//   6: black         (solid 0x00 — emitter-off verification)
//   7: white         (solid 0xFF — emitter-on verification)
//
// 2026-05-28 v3.1: bumped resolution 530x240 -> 480x360 (4:3) for
// integer-scale-clean test patterns on 1080p/4K monitors. Grid spacing
// stays at 16px (cheap bit check); 480-wide hosts 30 cell columns,
// 360-tall hosts 22.5 rows. Cells are square (1:1) because source
// aspect now matches the framework's 4:3 VIDEO_ARX/VIDEO_ARY default.
// Crosshair center moved to (240, 180).

module mycore
(
	input         clk,
	input         reset,

	input         pal,
	input         scandouble,
	input   [2:0] pattern,         // SPEC-vis_warp-v3 task #6

	output reg    ce_pix,

	output reg    HBlank,
	output reg    HSync,
	output reg    VBlank,
	output reg    VSync,

	output  [7:0] video
);

// ---- Timing constants (480x360 active, ~600x400 NTSC / ~600x480 PAL) ----
// Pixel rate at clk: NTSC 60Hz = ~14.4 Mpx/s ; PAL 50Hz = ~14.4 Mpx/s
// At pll's 20 MHz clk_sys, ce_pix toggles by default to halve rate.
// scandouble=1 means pixels emitted every clk cycle (= 20 Mpx/s effective).

localparam HTOTAL        = 600;   // hc loops 0..599
localparam HACTIVE       = 480;   // HBlank starts at hc==480
localparam HSYNC_START   = 510;
localparam HSYNC_END     = 560;

localparam VACTIVE       = 360;   // VBlank starts at vc==360
localparam VTOTAL_NTSC   = 400;   // 60Hz total
localparam VTOTAL_PAL    = 480;   // 50Hz total
localparam VSYNC_NTSC_S  = 365;
localparam VSYNC_NTSC_E  = 369;
localparam VSYNC_PAL_S   = 460;
localparam VSYNC_PAL_E   = 464;

reg   [9:0] hc;
reg   [9:0] vc;
reg   [9:0] vvc;
reg  [63:0] rnd_reg;

wire  [5:0] rnd_c = {rnd_reg[0],rnd_reg[1],rnd_reg[2],rnd_reg[2],rnd_reg[2],rnd_reg[2]};
wire [63:0] rnd;

lfsr random(rnd);

always @(posedge clk) begin
	if(scandouble) ce_pix <= 1;
		else ce_pix <= ~ce_pix;

	if(reset) begin
		hc <= 0;
		vc <= 0;
	end
	else if(ce_pix) begin
		if(hc == (HTOTAL - 1)) begin
			hc <= 0;
			if(vc == (pal ? (scandouble ? (2*VTOTAL_PAL  - 1) : (VTOTAL_PAL  - 1))
			              : (scandouble ? (2*VTOTAL_NTSC - 1) : (VTOTAL_NTSC - 1)))) begin
				vc <= 0;
				vvc <= vvc + 9'd6;
			end else begin
				vc <= vc + 1'd1;
			end
		end else begin
			hc <= hc + 1'd1;
		end

		rnd_reg <= rnd;
	end
end

always @(posedge clk) begin
	if (hc == HACTIVE) HBlank <= 1;
		else if (hc == 0) HBlank <= 0;

	if (hc == HSYNC_START) begin
		HSync <= 1;

		if(pal) begin
			if(vc == (scandouble ? (2*VSYNC_PAL_S) : VSYNC_PAL_S)) VSync <= 1;
				else if (vc == (scandouble ? (2*VSYNC_PAL_E) : VSYNC_PAL_E)) VSync <= 0;

			if(vc == (scandouble ? (2*VACTIVE) : VACTIVE)) VBlank <= 1;
				else if (vc == 0) VBlank <= 0;
		end
		else begin
			if(vc == (scandouble ? (2*VSYNC_NTSC_S) : VSYNC_NTSC_S)) VSync <= 1;
				else if (vc == (scandouble ? (2*VSYNC_NTSC_E) : VSYNC_NTSC_E)) VSync <= 0;

			if(vc == (scandouble ? (2*VACTIVE) : VACTIVE)) VBlank <= 1;
				else if (vc == 0) VBlank <= 0;
		end
	end

	if (hc == HSYNC_END) HSync <= 0;
end

// ---- Pattern: cosine+LFSR (original) ----
reg  [7:0] cos_out;
wire [5:0] cos_g = cos_out[7:3]+6'd32;
cos cos(vvc + {vc>>scandouble, 2'b00}, cos_out);

wire [7:0] pat_cosine = (cos_g >= rnd_c) ? {cos_g - rnd_c, 2'b00} : 8'd0;

// ---- Pattern: grid (16px spacing, cheap bit check, square cells) ----
// 480-wide / 16 = 30 columns, 360-tall / 16 = 22.5 rows. Cell aspect 1:1
// (square) — visually unambiguous for warp eval when displayed at 4:3.
wire grid_h_line = (hc[3:0] == 4'd0);
wire grid_v_line = (vc[3:0] == 4'd0);
wire [7:0] pat_grid = (grid_h_line | grid_v_line) ? 8'hFF : 8'h10;

// ---- Pattern: vertical bars (32px wide alternating) ----
wire [7:0] pat_vbars = hc[5] ? 8'hE0 : 8'h20;

// ---- Pattern: horizontal gradient (continuous sweep) ----
// hc 0..479 mapped to intensity. Use upper 8 bits scaled to 256 range.
// At hc=479, hc[8:1] = 239 ≈ near-full white.
wire [7:0] pat_gradient = hc[8:1];

// ---- Pattern: center crosshair ----
// Active area: 480x360. Center: (240, 180). PAL/NTSC same active region,
// just different VTOTAL (frame rate).
wire [9:0] vcenter = scandouble ? 10'd360 : 10'd180;
wire [9:0] hcenter = 10'd240;
wire crosshair_h_pix = (vc == vcenter);
wire crosshair_v_pix = (hc == hcenter);
wire [7:0] pat_crosshair = (crosshair_h_pix | crosshair_v_pix) ? 8'hFF : 8'h00;

// ---- Solid patterns ----
wire [7:0] pat_gray50 = 8'h80;
wire [7:0] pat_black  = 8'h00;
wire [7:0] pat_white  = 8'hFF;

// ---- Mux ----
reg [7:0] pat_sel;
always @* begin
	case (pattern)
		3'd0: pat_sel = pat_cosine;
		3'd1: pat_sel = pat_grid;
		3'd2: pat_sel = pat_vbars;
		3'd3: pat_sel = pat_gradient;
		3'd4: pat_sel = pat_crosshair;
		3'd5: pat_sel = pat_gray50;
		3'd6: pat_sel = pat_black;
		3'd7: pat_sel = pat_white;
	endcase
end

assign video = pat_sel;

endmodule
