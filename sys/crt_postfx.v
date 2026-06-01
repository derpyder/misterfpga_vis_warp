//============================================================================
//  crt_postfx — post-warp CRT screen effect: radial vignette
//
//  Standalone, fully decoupled from vis_warp (operates on its OUTPUT raster), so
//  it cannot affect the warp geometry or the hi-res de-doubling. Self-contained:
//  measures the active area (W,H) from the sync, computes per-axis reciprocals
//  once per frame (repeated-subtraction divide during blanking), then a fixed-
//  latency per-pixel pipeline darkens the edges (vignette).
//
//  Math is the Q15 model validated in sim/crt_postfx_proto.py:
//    nx = min(|ox-W/2| * recip_w, 32768)            (Q15, 1.0 = 32768)
//    ny = min(|oy-H/2| * recip_h, 32768)
//    r2 = min((nx*nx + ny*ny) >> 15, 32768)
//    vfac = 32768 - min((vignette*4096) * r2 >> 15, 32768)
//    rgb  = (rgb * vfac) >> 15
//
//  vignette=0  ->  transparent passthrough (vfac=32768);
//  {rgb,hs,vs,de} are all delayed LAT cycles together so downstream sync holds.
//
//  (Rounded-corner masking lived here in an earlier revision; removed because a
//  raster-anchored mask rounds the black border, not the barrel-warped content,
//  and the content-following variant produced wave artifacts. Vignette only.)
//============================================================================

module crt_postfx
(
	input             clk,
	input             ce,        // pixel enable (= warp emit; rate unchanged)

	input       [7:0] r_in,
	input       [7:0] g_in,
	input       [7:0] b_in,
	input             hs_in,
	input             vs_in,
	input             de_in,

	input       [2:0] vignette,  // 0=off .. 7=strong

	output reg  [7:0] r_out,
	output reg  [7:0] g_out,
	output reg  [7:0] b_out,
	output reg        hs_out,
	output reg        vs_out,
	output reg        de_out
);

	localparam LAT = 4;          // video-delay depth == factor-pipeline depth

	// ---- raster position tracking + active-area measurement (ce domain) ----
	reg [11:0] ox = 0, oy = 0;
	reg [11:0] w_cur = 0;
	reg [11:0] W = 576, H = 240;          // last-frame dims (sane defaults)
	reg        de_d = 0, vs_d = 0;

	// Edge detection + active-area measurement run on the CONTINUOUS clock:
	// de-falling and vsync occur during blanking when ce (the warp emit) is LOW,
	// so gating this whole block by ce was the bug -- de-falling was never seen,
	// the line counter (oy) stuck at 0, and every pixel read as the top edge ->
	// the vertical vignette darkened the WHOLE frame. ox advances only on an
	// actually-emitted active pixel (de & ce). Dim latches are sanity-bounded.
	always @(posedge clk) begin
		de_d <= de_in;
		vs_d <= vs_in;

		if (de_in & ce) begin
			ox <= ox + 1'b1;
		end else if (~de_in & de_d) begin  // de falling: end of an active line
			if (ox > w_cur) w_cur <= ox;
			ox <= 0;
			oy <= oy + 1'b1;
		end

		if (vs_in & ~vs_d) begin           // vsync rising: latch frame, restart
			if (w_cur > 12'd32) W <= w_cur; // reject degenerate measurements
			if (oy    > 12'd32) H <= oy;
			w_cur <= 0;
			oy    <= 0;
			ox    <= 0;
		end
	end

	wire [11:0] halfW = W[11:1];
	wire [11:0] halfH = H[11:1];

	// ---- per-frame reciprocals: recip = floor(32768/half) by repeated subtraction.
	// Runs on clk (not ce); ~halfW iterations (<~400), retriggered only when a
	// half-dim changes (game/res change). Completes long before the next frame.
	reg [16:0] recip_w = 114, recip_h = 273;
	reg [16:0] sub_acc = 0, sub_cnt = 0;
	reg [11:0] sub_d = 0;
	reg        sub_busy = 0, sub_tgt = 0;
	reg [11:0] last_hW = 0, last_hH = 0;
	always @(posedge clk) begin
		if (!sub_busy) begin
			if (halfW != last_hW && halfW != 0) begin
				sub_d <= halfW; sub_acc <= 17'd32768; sub_cnt <= 0;
				sub_busy <= 1; sub_tgt <= 1'b0; last_hW <= halfW;
			end else if (halfH != last_hH && halfH != 0) begin
				sub_d <= halfH; sub_acc <= 17'd32768; sub_cnt <= 0;
				sub_busy <= 1; sub_tgt <= 1'b1; last_hH <= halfH;
			end
		end else begin
			if (sub_acc >= {5'd0, sub_d}) begin
				sub_acc <= sub_acc - {5'd0, sub_d};
				sub_cnt <= sub_cnt + 1'b1;
			end else begin
				if (sub_tgt == 1'b0) recip_w <= sub_cnt;
				else                 recip_h <= sub_cnt;
				sub_busy <= 0;
			end
		end
	end

	// ---- strength map ----
	wire [16:0] vstr_q = vignette * 14'd4096;   // 0..28672

	// ---- per-pixel vignette pipeline (LAT deep), input pixel = "P" at T+0 ----
	wire [11:0] adx = (ox >= halfW) ? (ox - halfW) : (halfW - ox);
	wire [11:0] ady = (oy >= halfH) ? (oy - halfH) : (halfH - oy);
	wire [28:0] mulx = adx * recip_w;
	wire [28:0] muly = ady * recip_h;

	// s1 (T+1): normalize to Q15, clamp 1.0
	reg [16:0] nx1, ny1;
	// s2 (T+2): radial square
	reg [16:0] r2_2;            // (nx^2+ny^2)>>15, pre-clamp fits 17b (max 0x10000)
	// s3 (T+3): clamp r2
	reg [16:0] r2_3;
	reg [16:0] vstr_3;
	// s4 (T+4): vignette factor
	reg [16:0] vfac4;

	// Full-width products in explicit wide wires. Verilog sizes a*b to the
	// assignment/context width, so "(nx1*nx1)>>15" written into a 17-bit target
	// truncates the 34-bit product to 17 bits BEFORE the shift -> garbage; and
	// "(pixel*vfac)>>15" into an 8-bit target collapsed to ~0 (whole-screen-black
	// bug). Computing each product into a wide wire forces the full multiply.
	wire [33:0] nx1_sq = nx1 * nx1;
	wire [33:0] ny1_sq = ny1 * ny1;
	wire [33:0] vig_pr = vstr_3 * r2_3;

	always @(posedge clk) if (ce) begin
		// s1
		nx1 <= (mulx > 29'd32768) ? 17'd32768 : mulx[16:0];
		ny1 <= (muly > 29'd32768) ? 17'd32768 : muly[16:0];
		// s2
		r2_2 <= (nx1_sq >> 15) + (ny1_sq >> 15);
		// s3
		r2_3   <= (r2_2 > 17'd32768) ? 17'd32768 : r2_2;
		vstr_3 <= vstr_q;
		// s4
		vfac4 <= 17'd32768 - ((vig_pr >> 15) > 17'd32768 ? 17'd32768 : (vig_pr >> 15));
	end

	// ---- video delay line (LAT deep), combined with the factor at the tail ----
	reg [7:0] r_p[0:LAT-1];
	reg [7:0] g_p[0:LAT-1];
	reg [7:0] b_p[0:LAT-1];
	reg       hs_p[0:LAT-1];
	reg       vs_p[0:LAT-1];
	reg       de_p[0:LAT-1];
	integer i;
	always @(posedge clk) if (ce) begin
		r_p[0] <= r_in; g_p[0] <= g_in; b_p[0] <= b_in;
		hs_p[0] <= hs_in; vs_p[0] <= vs_in; de_p[0] <= de_in;
		for (i = 1; i < LAT; i = i + 1) begin
			r_p[i] <= r_p[i-1]; g_p[i] <= g_p[i-1]; b_p[i] <= b_p[i-1];
			hs_p[i] <= hs_p[i-1]; vs_p[i] <= vs_p[i-1]; de_p[i] <= de_p[i-1];
		end
	end

	// tail (T+4): apply vignette (vfac4) to r_p[LAT-1] (=P at T+4). Wide product
	// wires (full 25-bit) so (pixel*vfac)>>15 keeps the high bits (truncation fix).
	wire [24:0] r_pr = r_p[LAT-1] * vfac4;
	wire [24:0] g_pr = g_p[LAT-1] * vfac4;
	wire [24:0] b_pr = b_p[LAT-1] * vfac4;
	always @(posedge clk) if (ce) begin
		hs_out <= hs_p[LAT-1];
		vs_out <= vs_p[LAT-1];
		de_out <= de_p[LAT-1];
		// vignette only (full-width product = the truncation fix). Corner round
		// removed entirely; no content_valid / black-edge work (those introduced
		// the wave/over-warp artifacts).
		if (de_p[LAT-1]) begin
			r_out <= r_pr[22:15];
			g_out <= g_pr[22:15];
			b_out <= b_pr[22:15];
		end else begin
			r_out <= 8'd0;
			g_out <= 8'd0;
			b_out <= 8'd0;
		end
	end

endmodule
