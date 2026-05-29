-- vis_warp_v2_wp -- "warp-as-parent" v2, site-C edition (2026-05-27 night)
--
-- ARCHITECTURE (post-2026-05-27 final): site C, pre-ascal, source resolution.
--   See ~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md for
--   the full design rationale (locked-in, not to be re-litigated).
--
-- Summary: vis_warp lives BETWEEN the game core's raw pixel output and
-- ascal's input. Operates at clk_video (game pixel clock), source
-- resolution (typically <=384 wide for arcade). Captures incoming
-- pixels into an N=128-line M10K sliding window. For each output pixel,
-- the warp pipeline produces (src_x, src_y); we read the buffer at that
-- address (clamping out-of-range src_y to the most recently-captured
-- line). ascal upscales the warped source frame to whatever HDMI mode
-- the user has configured, so the bow scales naturally with the
-- integer scaling factor.
--
-- Port signature has CHANGED from the prior DDR3-based design:
--   - No more avl_* (no DDR3 access; vbuf belongs to ascal).
--   - r/g/b separate 8-bit signals (match ascal's i_r/g/b input shape).
--   - ce_pix in (= pixel-clock enable; pipeline gated on this).
--   - No more dst_w / dst_h external inputs. Source dims are
--     auto-detected internally by counting active de_in pulses per line
--     and active lines per frame, latched on vs_in rising. Default
--     defaults (288 x 224) cover the first frame before detection.
--
-- Buffer layout: pixel_buf(addr) holds RGB888 packed as 24 bits, where
--   addr = (cnt_y mod N_LINES) * MAX_SRC_W + cnt_x.
-- M10K cost at MAX_SRC_W=512, N_LINES=128, RGB888:
--   65536 entries * 24 bits = 1.57 Mbit ≈ 165 M10K blocks (~30% of 553).
-- Sync buffer (delayed hs/vs/de pass-through, gated on de_in): 3-bit
--   parallel buffer of the same depth, ~20 M10K blocks. Total ≈ 33% M10K.
--
-- Latency: 16-stage warp math + 1-cycle M10K read = 17 clk_video cycles
-- per pixel. At typical clk_video ~6 MHz that's ~2.8 us, well under one
-- scanline. No frame-level lookahead in this v1 — src_y is clamped to
-- the most-recently-captured line, so the top N_LINES/2 rows of output
-- have a "weakened" warp where the corner curvature would otherwise
-- pull from future lines. v2 adds the N/2-line lookahead by delaying
-- output sync.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.vis_warp_pkg_v2.all;
use work.vis_warp_luts_pkg.all;

entity vis_warp_v2_wp is
    generic (
        MAX_SRC_W : integer := 512;     -- max source width supported
        N_LINES   : integer := 128;     -- M10K sliding-window depth
        ARX       : integer := 4;       -- aspect ratio (for warp math)
        ARY       : integer := 3
    );
    port (
        clk         : in  std_logic;        -- = clk_video
        reset       : in  std_logic;

        warp_en     : in  std_logic;
        curvature_k : in  unsigned(2 downto 0);
        bilinear_en : in  std_logic;        -- 1=bilinear (4-bank pixel fetch), 0=NN

        ce_pix      : in  std_logic;        -- pixel enable

        r_in        : in  std_logic_vector(7 downto 0);
        g_in        : in  std_logic_vector(7 downto 0);
        b_in        : in  std_logic_vector(7 downto 0);
        hs_in       : in  std_logic;
        vs_in       : in  std_logic;
        de_in       : in  std_logic;

        r_out       : out std_logic_vector(7 downto 0);
        g_out       : out std_logic_vector(7 downto 0);
        b_out       : out std_logic_vector(7 downto 0);
        hs_out      : out std_logic;
        vs_out      : out std_logic;
        de_out      : out std_logic
    );

    attribute keep    : boolean;
    attribute noprune : boolean;
    attribute keep    of warp_en     : signal is true;
    attribute noprune of warp_en     : signal is true;
    attribute keep    of curvature_k : signal is true;
    attribute noprune of curvature_k : signal is true;
    attribute keep    of bilinear_en : signal is true;
    attribute noprune of bilinear_en : signal is true;
end entity;

architecture rtl of vis_warp_v2_wp is

    -- ---- Derived sizes ----
    -- v3.1: pixel buffer is split into 4 banks by (x mod 2, y mod 2) so all
    -- 4 bilinear neighbors can be fetched in a single clk cycle. Total
    -- storage is unchanged (same number of pixels, same bit depth); only
    -- the bank arrangement differs. Each bank's depth is the original
    -- BUFFER_DEPTH/4. Per-bank parameters:
    --   N_HLINES   = N_LINES / 2     -- 64 half-rows per bank
    --   HALF_W     = MAX_SRC_W / 2   -- 256 half-cols per bank
    --   BANK_DEPTH = N_HLINES * HALF_W = 64 * 256 = 16384 entries
    -- At RGB888 (24 bits): 16384 * 24 = ~38 M10K blocks per bank → ~152
    -- across all 4 banks (vs ~165 for the prior single-bank layout).
    constant BUFFER_DEPTH : integer := N_LINES * MAX_SRC_W;
    constant N_HLINES     : integer := N_LINES / 2;     -- 64
    constant HALF_W       : integer := MAX_SRC_W / 2;   -- 256
    constant BANK_DEPTH   : integer := N_HLINES * HALF_W;
    constant LINE_ADDR_W  : integer := 7;   -- log2(N_LINES) = log2(128)
    constant COL_ADDR_W   : integer := 9;   -- log2(MAX_SRC_W) = log2(512)

    -- ---- Pixel banks (M10K-inferred, 4-way split) ----
    -- Naming: pb_<y_parity><x_parity>. e.g. pb_eo holds pixels with even
    -- y and odd x. Every input pixel writes to exactly one bank. Every
    -- read cycle reads from ALL four banks; the bilinear muxer routes
    -- each bank output to one of (p00, p01, p10, p11) based on the
    -- low bit of floor_x / floor_y.
    type pixel_bank_t is array (0 to BANK_DEPTH - 1) of std_logic_vector(23 downto 0);
    signal pb_ee : pixel_bank_t;  -- y even, x even
    signal pb_eo : pixel_bank_t;  -- y even, x odd
    signal pb_oe : pixel_bank_t;  -- y odd,  x even
    signal pb_oo : pixel_bank_t;  -- y odd,  x odd
    -- (sync_buf removed: sync state travels via side_pipe + s12_*/s13_*
    -- registered chain, not via M10K. The previous sync_buf signal was
    -- a dead write port and confused the synthesizer.)

    -- ---- Input edge detect ----
    signal hs_in_d, vs_in_d, de_in_d : std_logic := '0';
    signal vs_rising  : std_logic;
    signal de_falling : std_logic;

    -- ---- Source-dim auto-detector (latches each vs_in rising) ----
    -- Counts active pixels per line and active lines per frame, then
    -- latches on vs_in rising. First frame uses defaults; second frame
    -- onward uses learned dims. Defaults (288, 224) cover Galaga.
    signal det_x_in_line  : integer range 0 to MAX_SRC_W := 0;
    signal det_x_max      : integer range 0 to MAX_SRC_W := 0;
    signal det_y_in_frame : integer range 0 to N_LINES * 4 := 0;
    signal src_w_latched  : integer range 0 to MAX_SRC_W := 288;
    signal src_h_latched  : integer range 0 to 4095      := 224;

    -- ---- Input write cursor (advances per ce_pix && de_in) ----
    signal cnt_x_w : integer range 0 to MAX_SRC_W := 0;
    signal cnt_y_w : integer range 0 to 4095      := 0;

    -- ============================================================
    -- v3.3b: SYNC-DELAY FIFO  (re-created 2026-05-28)
    -- ============================================================
    -- Delays the OUTPUT raster by ~N_LINES/2 source lines so the writer
    -- LEADS the reader. With the buffer always holding ~±N_LINES/2 lines
    -- around the output line, the warp gets bidirectional lookahead and
    -- the top-of-frame asymmetry (warp pulling stale/garbage forward
    -- lines) goes away.
    --
    -- Mechanism: a 65536 × 4-bit simple-dual-port RAM (target: M9K/M10K
    -- inference, Quartus canonical template) carries {hs,vs,de,ce_pix}.
    -- We write the live input sync into wr_ptr and read out a delayed
    -- copy from rd_ptr every clk. rd_ptr starts SYNC_FIFO_LATENCY cycles
    -- behind wr_ptr, so the popped sync (hs_o_gen/vs_o_gen/de_o_gen/
    -- ce_pix_dly) trails the input by N_LINES/2 source lines.
    --
    -- v3.3c SELF-TUNING (2026-05-28): the writer-lead must be ~N_LINES/2
    -- *lines* regardless of the core's line period — that is what lets an
    -- arbitrary core adopt this template cleanly with NO per-core magic
    -- constant. We measure the line period (clk cycles between hs_in
    -- rising edges) into line_len, then set target_lag = (N_LINES/2) *
    -- line_len, and make rd_ptr trail wr_ptr by exactly target_lag. So the
    -- read is ~N_LINES/2 lines behind the write on ANY htotal.
    -- The MAX_HTOTAL/LATENCY constants below are now just the FIRST-FRAME
    -- DEFAULT (used until line_len is measured) and the cap so the lag
    -- never exceeds the FIFO depth.
    constant MAX_HTOTAL         : integer := 768;   -- default/cap source HTotal
    constant SYNC_FIFO_DEPTH    : integer := 65536;
    constant SYNC_FIFO_LATENCY  : integer := (N_LINES / 2) * MAX_HTOTAL;  -- 49152 default
    constant SYNC_FIFO_RD_INIT  : integer := SYNC_FIFO_DEPTH - SYNC_FIFO_LATENCY; -- 16384
    constant LINE_LEN_MAX       : integer := 1023;  -- cap so (N/2)*line_len < DEPTH (1023*64=65472)
    constant LINE_LEN_MIN       : integer := 64;    -- ignore implausibly short lines (hs glitch)

    -- v3.3d SHARP-BILINEAR: steepen the bilinear blend fraction so pixels
    -- snap to their nearest source pixel (crisp) except a thin transition
    -- band at pixel boundaries (keeps curves smooth, kills the global
    -- resample fuzz). SHARP_K=1 → pure bilinear (soft); higher → sharper
    -- (→ nearest-neighbor as K→∞). K=2 = classic sharp-bilinear (½-pixel
    -- transition); K=3 sharper (⅓-pixel). Tune to taste.
    constant SHARP_K            : integer := 2;

    type sync_fifo_t is array (0 to SYNC_FIFO_DEPTH - 1) of std_logic_vector(3 downto 0);
    signal sync_fifo        : sync_fifo_t;   -- {hs,vs,de,ce_pix} -- NO init/reset → M9K
    signal sync_fifo_out    : std_logic_vector(3 downto 0) := (others => '0');
    signal sync_fifo_wr_ptr : unsigned(15 downto 0) := (others => '0');
    signal sync_fifo_rd_ptr : unsigned(15 downto 0) := to_unsigned(SYNC_FIFO_RD_INIT, 16);

    -- Self-tuning line-period measurement → dynamic FIFO lag.
    signal line_meas_cnt : unsigned(11 downto 0) := (others => '0');               -- cycles in current line
    signal line_len      : unsigned(11 downto 0) := to_unsigned(MAX_HTOTAL, 12);   -- measured period (default 768)
    signal target_lag    : unsigned(15 downto 0) := to_unsigned(SYNC_FIFO_LATENCY, 16); -- = (N/2)*line_len
    signal hs_in_meas_d  : std_logic := '0';                                       -- hs_in edge detect

    -- Delayed sync popped from the FIFO (concurrent slices of sync_fifo_out).
    signal hs_o_gen   : std_logic;
    signal vs_o_gen   : std_logic;
    signal de_o_gen   : std_logic;
    signal ce_pix_dly : std_logic;

    -- Edge detect on the DELAYED sync (for the output cursor process).
    signal vs_o_gen_d  : std_logic := '0';
    signal de_o_gen_d  : std_logic := '0';
    signal vs_o_rising : std_logic;
    signal de_o_falling: std_logic;

    -- ---- Output read cursor (DELAYED by ~N_LINES/2 lines) ----
    -- Derived from the FIFO-popped sync, mirroring the input write-cursor
    -- rules but in the delayed domain. cnt_y_o lags cnt_y_w by ~N_LINES/2.
    -- The warp pipeline + stage-12 buffer-window clamp now key off these.
    signal cnt_x_o : integer range 0 to MAX_SRC_W := 0;
    signal cnt_y_o : integer range 0 to 4095      := 0;

    -- ============================================================
    -- WARP PIPELINE (salvaged verbatim from prior DDR3 design)
    -- ============================================================
    -- Same 16-stage math; only difference is it now drives an M10K
    -- read address at stage 12 instead of a DDR3 word address.
    constant N_WARP_STAGES : integer := 16;

    type warp_side_t is record
        cnt_x_o  : integer range 0 to MAX_SRC_W + 4095;
        cnt_y_o  : integer range 0 to 4095;
        dx       : signed(15 downto 0);
        dy       : signed(15 downto 0);
        hs       : std_logic;
        vs       : std_logic;
        de       : std_logic;
        v_in_act : std_logic;
        warp_en  : std_logic;
        k        : unsigned(2 downto 0);
    end record;

    constant WARP_SIDE_ZERO : warp_side_t := (
        cnt_x_o => 0, cnt_y_o => 0,
        dx => (others => '0'), dy => (others => '0'),
        hs => '0', vs => '0', de => '0',
        v_in_act => '0', warp_en => '0',
        k => (others => '0')
    );

    type warp_side_pipe_t is array (1 to N_WARP_STAGES) of warp_side_t;
    signal side_pipe : warp_side_pipe_t := (others => WARP_SIDE_ZERO);

    -- Arithmetic-pipeline signals (verbatim names from prior design)
    signal s2_dx2, s2_dy2          : signed(26 downto 0) := (others => '0');
    signal s3_ax2dx2, s3_ay2dy2    : signed(30 downto 0) := (others => '0');
    signal s4_r2                   : signed(31 downto 0) := (others => '0');
    signal s5_m_lo, s5_m_hi        : unsigned(15 downto 0) := (others => '0');
    signal s5_frac                 : unsigned(7 downto 0) := (others => '0');
    signal s5b_m_lo, s5b_m_hi      : unsigned(15 downto 0) := (others => '0');
    signal s5b_frac                : unsigned(7 downto 0) := (others => '0');
    signal s5c_m_diff              : signed(16 downto 0) := (others => '0');
    signal s5c_m_lo                : unsigned(15 downto 0) := (others => '0');
    signal s5c_frac                : unsigned(7 downto 0) := (others => '0');
    signal s6_m_diff_frac          : signed(24 downto 0) := (others => '0');
    signal s6_m_lo                 : unsigned(15 downto 0) := (others => '0');
    signal s7_m_raw                : unsigned(15 downto 0) := (others => '0');
    signal s7b_m_centered          : signed(17 downto 0) := (others => '0');
    signal s8_m_scaled_pre         : signed(20 downto 0) := (others => '0');
    signal s9_m_scaled             : unsigned(15 downto 0) := (others => '0');
    signal s10_dx_m, s10_dy_m      : signed(31 downto 0) := (others => '0');
    signal s10b_src_x_q15          : signed(31 downto 0) := (others => '0');
    signal s10b_src_y_q15          : signed(31 downto 0) := (others => '0');
    signal s11_src_x, s11_src_y    : integer range 0 to 4095 := 0;
    -- s11_fx / s11_fy: 8-bit fractional parts of warped (src_x, src_y),
    -- representing values in [0, 256). Extracted from s10b_*_q15 bits
    -- [14:7]. Used by the bilinear stages 14/15. NN path ignores them.
    signal s11_fx, s11_fy          : unsigned(7 downto 0) := (others => '0');

    -- Stage 12: per-bank read addresses (4 banks → 4 read addresses)
    -- plus the fractional parts and the parity bits floor_x[0]/floor_y[0]
    -- needed by stage 13's bank-to-(p00,p01,p10,p11) muxing. Sync (hs/vs/de)
    -- carries through alongside.
    signal s12_addr_ee, s12_addr_eo, s12_addr_oe, s12_addr_oo
        : integer range 0 to BANK_DEPTH - 1 := 0;
    signal s12_fx, s12_fy          : unsigned(7 downto 0) := (others => '0');
    signal s12_fxp, s12_fyp        : std_logic := '0';  -- floor_x[0], floor_y[0]
    signal s12_hs, s12_vs, s12_de  : std_logic := '0';
    signal s12_bilinear            : std_logic := '0';

    -- Stage 13: bank read data captured (1-cycle latency). After muxing
    -- by (s12_fxp, s12_fyp), routed to (p00, p01, p10, p11).
    -- s13_q_ee/eo/oe/oo are the raw bank outputs; p00..p11 are the
    -- muxed bilinear neighbours.
    signal s13_q_ee, s13_q_eo, s13_q_oe, s13_q_oo
        : std_logic_vector(23 downto 0) := (others => '0');
    signal s13_p00, s13_p01, s13_p10, s13_p11
        : std_logic_vector(23 downto 0) := (others => '0');
    signal s13_fx, s13_fy          : unsigned(7 downto 0) := (others => '0');
    signal s13_hs, s13_vs, s13_de  : std_logic := '0';
    signal s13_bilinear            : std_logic := '0';
    -- Back-compat alias: legacy code (output emitter) used s13_pixel as
    -- the NN output. With bilinear gating the emitter consumes s16_pixel.
    -- s13_pixel is kept only as the un-muxed NN pixel for traceability
    -- via SignalTap, but no longer drives r/g/b_out.
    signal s13_pixel               : std_logic_vector(23 downto 0) := (others => '0');

    -- Stage 14: horizontal lerp. Per channel:
    --   top_<c> = p00.<c> * (256 - fx) + p01.<c> * fx       -- 16-bit
    --   bot_<c> = p10.<c> * (256 - fx) + p11.<c> * fx       -- 16-bit
    -- Width: 8-bit pixel * 9-bit weight (max 256) = 17-bit max, but
    -- the sum of (a*(256-fx) + b*fx) is bounded by 255*256 = 65280, so
    -- 16 bits suffice. We use 17 bits to keep headroom for the synth.
    signal s14_top_r, s14_top_g, s14_top_b : unsigned(16 downto 0) := (others => '0');
    signal s14_bot_r, s14_bot_g, s14_bot_b : unsigned(16 downto 0) := (others => '0');
    signal s14_fy          : unsigned(7 downto 0) := (others => '0');
    signal s14_hs, s14_vs, s14_de : std_logic := '0';
    signal s14_bilinear    : std_logic := '0';
    -- NN pass-through alongside the bilinear math (so we can mux at s16).
    signal s14_p00         : std_logic_vector(23 downto 0) := (others => '0');

    -- Stage 15: vertical lerp. Per channel:
    --   out_<c>_25 = top_<c> * (256 - fy) + bot_<c> * fy    -- 17*9 + 17*9 = 26-bit
    -- We need to >>16 to recover the final 8-bit channel value.
    -- Width: 17 * 9 = 26 bits max → use 26-bit signal, then take [23:16].
    signal s15_r25, s15_g25, s15_b25 : unsigned(25 downto 0) := (others => '0');
    signal s15_hs, s15_vs, s15_de : std_logic := '0';
    signal s15_bilinear    : std_logic := '0';
    signal s15_p00         : std_logic_vector(23 downto 0) := (others => '0');

    -- Stage 16: final pixel — mux between bilinear result and NN p00.
    signal s16_pixel : std_logic_vector(23 downto 0) := (others => '0');
    signal s16_hs, s16_vs, s16_de : std_logic := '0';

    -- ============================================================
    -- Helper functions (verbatim from prior design)
    -- ============================================================
    function warp_m_lookup(r2_q24 : unsigned(31 downto 0)) return unsigned is
        variable r2_sat : unsigned(23 downto 0);
        variable idx   : integer range 0 to 255;
        variable frac  : unsigned(7 downto 0);
        variable m_lo, m_hi : unsigned(15 downto 0);
        variable diff  : signed(16 downto 0);
        variable prod  : signed(25 downto 0);
    begin
        if r2_q24 >= to_unsigned(2**24, 32) then
            r2_sat := (others => '1');
        else
            r2_sat := r2_q24(23 downto 0);
        end if;
        idx  := to_integer(r2_sat(23 downto 16));
        frac := r2_sat(15 downto 8);
        m_lo := WARP_LUT(idx);
        m_hi := WARP_LUT(idx + 1);
        diff := signed('0' & std_logic_vector(m_hi)) - signed('0' & std_logic_vector(m_lo));
        prod := diff * signed('0' & std_logic_vector(frac));
        return m_lo + unsigned(prod(23 downto 8));
    end function;

    function scale_m_by_curv(m_raw : unsigned(15 downto 0);
                             k     : unsigned(2 downto 0)) return unsigned is
        variable m_delta  : signed(17 downto 0);
        variable m_scaled : signed(20 downto 0);
        variable result   : signed(17 downto 0);
    begin
        m_delta  := resize(signed('0' & std_logic_vector(m_raw)) - to_signed(32768, 17), 18);
        m_scaled := m_delta * signed('0' & std_logic_vector(k));
        result   := to_signed(32768, 18) + resize(shift_right(m_scaled, 1), 18);
        if result < 0 then
            return to_unsigned(0, 16);
        elsif result > 65535 then
            return to_unsigned(65535, 16);
        else
            return resize(unsigned(std_logic_vector(result)), 16);
        end if;
    end function;

begin

    -- ============================================================
    -- Input edge detect (combinational from registered _d signals)
    -- ============================================================
    vs_rising  <= '1' when (vs_in = '1' and vs_in_d = '0') else '0';
    de_falling <= '1' when (de_in = '0' and de_in_d = '1') else '0';

    -- ============================================================
    -- v3.3b: SYNC-DELAY FIFO  (simple-dual-port M9K)
    -- ============================================================
    -- (1) RAM access — UNCONDITIONAL on clk (no reset on RAM contents,
    --     NO ce_pix gate). This is the canonical Quartus simple-dual-
    --     port template: one write port, one read port, both registered.
    --     Keeping it free of any conditional inference logic ensures it
    --     maps to M9K/M10K rather than LUTRAM. {hs,vs,de,ce_pix} packed
    --     MSB→LSB so the concurrent slices below line up bit (3..0).
    process(clk)
    begin
        if rising_edge(clk) then
            sync_fifo(to_integer(sync_fifo_wr_ptr)) <= hs_in & vs_in & de_in & ce_pix;
            sync_fifo_out <= sync_fifo(to_integer(sync_fifo_rd_ptr));
        end if;
    end process;

    -- (2) Pointer advance — wr_ptr free-runs; rd_ptr tracks (wr_ptr+1) -
    --     target_lag so the read is ALWAYS exactly target_lag cycles
    --     (= N_LINES/2 lines) behind the write, self-correcting whenever
    --     target_lag updates. 16-bit unsigned subtraction wraps mod 65536.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                sync_fifo_wr_ptr <= (others => '0');
                sync_fifo_rd_ptr <= to_unsigned(SYNC_FIFO_RD_INIT, 16);
            else
                sync_fifo_wr_ptr <= sync_fifo_wr_ptr + 1;
                sync_fifo_rd_ptr <= (sync_fifo_wr_ptr + 1) - target_lag;
            end if;
        end if;
    end process;

    -- (3) SELF-TUNING line-period measurement. Count clk cycles between
    --     hs_in rising edges → line_len; target_lag = (N_LINES/2)*line_len
    --     = line_len << 6 (N_LINES/2 = 64). Cap line_len so the lag stays
    --     inside the FIFO; ignore implausibly short lines (hs glitches).
    process(clk)
    begin
        if rising_edge(clk) then
            hs_in_meas_d <= hs_in;
            if hs_in = '1' and hs_in_meas_d = '0' then
                if line_meas_cnt >= to_unsigned(LINE_LEN_MAX, 12) then
                    line_len <= to_unsigned(LINE_LEN_MAX, 12);
                elsif line_meas_cnt >= to_unsigned(LINE_LEN_MIN, 12) then
                    line_len <= line_meas_cnt;
                end if;
                line_meas_cnt <= (others => '0');
            elsif line_meas_cnt < to_unsigned(LINE_LEN_MAX, 12) then
                line_meas_cnt <= line_meas_cnt + 1;
            end if;
            -- target_lag = line_len * 64  (N_LINES/2). line_len<=1023 → <=65472.
            target_lag <= shift_left(resize(line_len, 16), 6);
        end if;
    end process;

    -- Expose the delayed sync. These trail the input by N_LINES/2 lines.
    hs_o_gen   <= sync_fifo_out(3);
    vs_o_gen   <= sync_fifo_out(2);
    de_o_gen   <= sync_fifo_out(1);
    ce_pix_dly <= sync_fifo_out(0);

    -- Edge detect on the delayed sync (combinational from _d copies).
    vs_o_rising  <= '1' when (vs_o_gen = '1' and vs_o_gen_d = '0') else '0';
    de_o_falling <= '1' when (de_o_gen = '0' and de_o_gen_d = '1') else '0';

    -- ============================================================
    -- Output read cursor (cnt_x_o / cnt_y_o) from the DELAYED sync.
    -- ============================================================
    -- Mirrors the input write-cursor rules, but uses the FIFO-popped
    -- edges and ce_pix_dly. The result lags cnt_x_w/cnt_y_w by ~N_LINES/2
    -- source lines, which is exactly the lookahead the warp wants.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                vs_o_gen_d <= '0';
                de_o_gen_d <= '0';
                cnt_x_o    <= 0;
                cnt_y_o    <= 0;
            elsif ce_pix_dly = '1' then
                vs_o_gen_d <= vs_o_gen;
                de_o_gen_d <= de_o_gen;
                if vs_o_rising = '1' then
                    cnt_x_o <= 0;
                    cnt_y_o <= 0;
                elsif de_o_falling = '1' then
                    cnt_x_o <= 0;
                    cnt_y_o <= cnt_y_o + 1;
                elsif de_o_gen = '1' then
                    cnt_x_o <= cnt_x_o + 1;
                end if;
            end if;
        end if;
    end process;

    -- ============================================================
    -- Source-dim auto-detector + input write cursor. All ce_pix-gated.
    -- (pixel_buf writes have moved to the dedicated RAM process below.)
    -- ============================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                hs_in_d <= '0';
                vs_in_d <= '0';
                de_in_d <= '0';
                cnt_x_w <= 0;
                cnt_y_w <= 0;
                det_x_in_line  <= 0;
                det_x_max      <= 0;
                det_y_in_frame <= 0;
                src_w_latched  <= 288;
                src_h_latched  <= 224;
            elsif ce_pix = '1' then
                -- 1-cycle delayed edge-detect copies (gated on ce_pix)
                hs_in_d <= hs_in;
                vs_in_d <= vs_in;
                de_in_d <= de_in;

                -- ---- Source-dim detector ----
                if vs_rising = '1' then
                    -- end of frame: latch and reset
                    if det_x_max > 0 then
                        src_w_latched <= det_x_max;
                    end if;
                    if det_y_in_frame > 0 then
                        src_h_latched <= det_y_in_frame;
                    end if;
                    det_x_max      <= 0;
                    det_x_in_line  <= 0;
                    det_y_in_frame <= 0;
                elsif de_falling = '1' and de_in_d = '1' then
                    -- end of active line
                    if det_x_in_line > det_x_max then
                        det_x_max <= det_x_in_line;
                    end if;
                    det_x_in_line <= 0;
                    if det_x_in_line > 0 then
                        det_y_in_frame <= det_y_in_frame + 1;
                    end if;
                elsif de_in = '1' then
                    det_x_in_line <= det_x_in_line + 1;
                end if;

                -- ---- Input write cursor + buffer write ----
                if vs_rising = '1' then
                    cnt_x_w <= 0;
                    cnt_y_w <= 0;
                elsif de_falling = '1' then
                    cnt_x_w <= 0;
                    cnt_y_w <= cnt_y_w + 1;
                elsif de_in = '1' then
                    -- (pixel_buf write moved to a dedicated single-process
                    -- block below for reliable M10K inference.)
                    cnt_x_w <= cnt_x_w + 1;
                end if;
            end if;
        end if;
    end process;

    -- ============================================================
    -- WARP PIPELINE (v3.3b: ce_pix_dly-gated, DELAYED read/output domain)
    -- ============================================================
    -- Stage 1: register current cycle's (cnt_x_o, cnt_y_o, dx, dy,
    -- hs_o_gen, vs_o_gen, de_o_gen) into side_pipe(1). These are the
    -- FIFO-delayed output position + sync, so the writer leads the reader.
    -- Stages 2..11: same arithmetic as the prior DDR3-based v2_wp.
    -- Stage 12: compute M10K read address from (src_x, src_y) clamped
    -- to (src_w_latched, src_h_latched) AND to the BIDIRECTIONAL window
    -- around the delayed output line:
    --   [cnt_y_o - N_LINES/2 + 1, cnt_y_o + N_LINES/2]  (min floored at 0).
    -- Stage 13: M10K read result (registered by M10K block).
    -- ============================================================
    process(clk)
        variable v_in_act  : boolean;
        variable v_dst_cx  : integer;
        variable v_dst_cy  : integer;
        variable v_dx_int  : integer;
        variable v_dy_int  : integer;
        variable v_idx     : integer range 0 to 256;
        variable v_frac    : unsigned(7 downto 0);
        variable v_m_acc   : integer;
        variable v_src_x_q15 : integer;
        variable v_src_y_q15 : integer;
        variable v_src_x_pre : integer;
        variable v_src_y_pre : integer;
        variable v_src_x_id  : integer;
        variable v_src_y_id  : integer;
        variable v_src_x_fin : integer;
        variable v_src_y_fin : integer;
        variable v_line_min  : integer;
        variable v_line_max  : integer;
        variable v_rd_addr   : integer;
        -- v3.1 (bilinear) — per-stage scratch:
        variable v_fx_u      : unsigned(7 downto 0);
        variable v_fy_u      : unsigned(7 downto 0);
        variable v_q15_pos_x : unsigned(30 downto 0);  -- abs value, for frac extraction
        variable v_q15_pos_y : unsigned(30 downto 0);
        -- Stage 12 bank-address scratch:
        variable v_fx_lo, v_fy_lo   : integer;        -- floor_x, floor_y (clamped)
        variable v_fx_hi, v_fy_hi   : integer;        -- floor_x+1, floor_y+1 (clamped)
        variable v_x_lo_h, v_x_hi_h : integer;        -- half-cols  (>>1)
        variable v_y_lo_h, v_y_hi_h : integer;        -- half-rows  (>>1)
        variable v_x_lo_p           : std_logic;      -- parity bit (floor_x[0])
        variable v_x_hi_p           : std_logic;      -- (kept for clarity; = not v_x_lo_p unless clamped)
        variable v_y_lo_p           : std_logic;
        variable v_y_hi_p           : std_logic;
        variable v_a_ee, v_a_eo     : integer;
        variable v_a_oe, v_a_oo     : integer;
        variable v_parity_sel       : std_logic_vector(1 downto 0);
        -- Stage 14 lerp scratch:
        variable v_one_minus_fx : unsigned(8 downto 0);
        -- Stage 15 lerp scratch:
        variable v_one_minus_fy : unsigned(8 downto 0);
        -- Sharp-bilinear: sharpened blend fractions + integer intermediates.
        variable v_fx_s, v_fy_s   : unsigned(7 downto 0);
        variable v_fxs_i, v_fys_i : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                side_pipe <= (others => WARP_SIDE_ZERO);
                s2_dx2 <= (others => '0'); s2_dy2 <= (others => '0');
                s3_ax2dx2 <= (others => '0'); s3_ay2dy2 <= (others => '0');
                s4_r2 <= (others => '0');
                s5_m_lo <= (others => '0'); s5_m_hi <= (others => '0');
                s5_frac <= (others => '0');
                s5b_m_lo <= (others => '0'); s5b_m_hi <= (others => '0');
                s5b_frac <= (others => '0');
                s5c_m_diff <= (others => '0'); s5c_m_lo <= (others => '0');
                s5c_frac <= (others => '0');
                s6_m_diff_frac <= (others => '0'); s6_m_lo <= (others => '0');
                s7_m_raw <= (others => '0');
                s7b_m_centered <= (others => '0');
                s8_m_scaled_pre <= (others => '0');
                s9_m_scaled <= (others => '0');
                s10_dx_m <= (others => '0'); s10_dy_m <= (others => '0');
                s10b_src_x_q15 <= (others => '0'); s10b_src_y_q15 <= (others => '0');
                s11_src_x <= 0; s11_src_y <= 0;
                s11_fx <= (others => '0'); s11_fy <= (others => '0');
                s12_addr_ee <= 0; s12_addr_eo <= 0;
                s12_addr_oe <= 0; s12_addr_oo <= 0;
                s12_fx <= (others => '0'); s12_fy <= (others => '0');
                s12_fxp <= '0'; s12_fyp <= '0';
                s12_hs <= '0'; s12_vs <= '0'; s12_de <= '0';
                s12_bilinear <= '0';
                -- (s13_q_ee/eo/oe/oo and s13_pixel are driven by the
                -- dedicated pixel-bank single-process block below; reset
                -- there.)
                s13_p00 <= (others => '0'); s13_p01 <= (others => '0');
                s13_p10 <= (others => '0'); s13_p11 <= (others => '0');
                s13_fx <= (others => '0'); s13_fy <= (others => '0');
                s13_hs <= '0'; s13_vs <= '0'; s13_de <= '0';
                s13_bilinear <= '0';
                s14_top_r <= (others => '0'); s14_top_g <= (others => '0');
                s14_top_b <= (others => '0');
                s14_bot_r <= (others => '0'); s14_bot_g <= (others => '0');
                s14_bot_b <= (others => '0');
                s14_fy <= (others => '0');
                s14_hs <= '0'; s14_vs <= '0'; s14_de <= '0';
                s14_bilinear <= '0';
                s14_p00 <= (others => '0');
                s15_r25 <= (others => '0'); s15_g25 <= (others => '0');
                s15_b25 <= (others => '0');
                s15_hs <= '0'; s15_vs <= '0'; s15_de <= '0';
                s15_bilinear <= '0';
                s15_p00 <= (others => '0');
                s16_pixel <= (others => '0');
                s16_hs <= '0'; s16_vs <= '0'; s16_de <= '0';
            elsif ce_pix_dly = '1' then
                -- Stage 1 input — DELAYED (read/output) domain.
                -- v3.3b: the warp renders the DELAYED output position
                -- (cnt_x_o/cnt_y_o), and the carried sync is the FIFO-
                -- popped sync (hs_o_gen/vs_o_gen/de_o_gen). The pipeline
                -- now advances on ce_pix_dly. The write side (cnt_x_w/
                -- cnt_y_w, bank writes) stays in the input domain.
                v_in_act := (de_o_gen = '1');
                v_dst_cx := src_w_latched / 2;
                v_dst_cy := src_h_latched / 2;
                v_dx_int := cnt_x_o - v_dst_cx;
                v_dy_int := cnt_y_o - v_dst_cy;

                -- side_pipe shift
                for k in 2 to N_WARP_STAGES loop
                    side_pipe(k) <= side_pipe(k - 1);
                end loop;

                side_pipe(1).cnt_x_o  <= cnt_x_o;
                side_pipe(1).cnt_y_o  <= cnt_y_o;
                side_pipe(1).dx       <= to_signed(v_dx_int, 16);
                side_pipe(1).dy       <= to_signed(v_dy_int, 16);
                side_pipe(1).hs       <= hs_o_gen;
                side_pipe(1).vs       <= vs_o_gen;
                side_pipe(1).de       <= de_o_gen;
                side_pipe(1).v_in_act <= de_o_gen;
                side_pipe(1).warp_en  <= warp_en;
                side_pipe(1).k        <= curvature_k;

                -- Stage 2: dx², dy² (parallel multipliers)
                s2_dx2 <= resize(side_pipe(1).dx * side_pipe(1).dx, s2_dx2'length);
                s2_dy2 <= resize(side_pipe(1).dy * side_pipe(1).dy, s2_dy2'length);

                -- Stage 3: AX2·dx², AY2·dy²
                s3_ax2dx2 <= resize(to_signed(LUT_AX2_Q24, 11) * s2_dx2, s3_ax2dx2'length);
                s3_ay2dy2 <= resize(to_signed(LUT_AY2_Q24, 11) * s2_dy2, s3_ay2dy2'length);

                -- Stage 4: r² = AX2·dx² + AY2·dy²
                s4_r2 <= resize(s3_ax2dx2, s4_r2'length)
                       + resize(s3_ay2dy2, s4_r2'length);

                -- Stage 5: LUT lookup (idx + frac from r²)
                if s4_r2 < 0 then
                    v_idx  := 0;
                    v_frac := (others => '0');
                elsif s4_r2 >= to_signed(2**24, s4_r2'length) then
                    v_idx  := 255;
                    v_frac := (others => '1');
                else
                    v_idx  := to_integer(unsigned(s4_r2(23 downto 16)));
                    v_frac := unsigned(s4_r2(15 downto 8));
                end if;
                s5_m_lo <= WARP_LUT(v_idx);
                s5_m_hi <= WARP_LUT(v_idx + 1);
                s5_frac <= v_frac;

                -- Stage 5b: FF buffer
                s5b_m_lo <= s5_m_lo;
                s5b_m_hi <= s5_m_hi;
                s5b_frac <= s5_frac;

                -- Stage 5c: m_diff sub
                s5c_m_diff <= signed('0' & std_logic_vector(s5b_m_hi))
                            - signed('0' & std_logic_vector(s5b_m_lo));
                s5c_m_lo   <= s5b_m_lo;
                s5c_frac   <= s5b_frac;

                -- Stage 6: m_diff * frac
                s6_m_diff_frac <= resize(
                    s5c_m_diff * signed('0' & std_logic_vector(s5c_frac)),
                    s6_m_diff_frac'length);
                s6_m_lo <= s5c_m_lo;

                -- Stage 7: m_raw = m_lo + (prod >> 8)
                s7_m_raw <= s6_m_lo + unsigned(s6_m_diff_frac(23 downto 8));

                -- Stage 7b: m_centered = m_raw - 32768
                s7b_m_centered <= resize(
                    signed('0' & std_logic_vector(s7_m_raw)) - to_signed(32768, 17),
                    s7b_m_centered'length);

                -- Stage 8: m_scaled_pre = m_centered * K
                s8_m_scaled_pre <= resize(
                    s7b_m_centered * signed('0' & std_logic_vector(side_pipe(10).k)),
                    s8_m_scaled_pre'length);

                -- Stage 9: clamp(32768 + m_scaled_pre/2)
                v_m_acc := to_integer(s8_m_scaled_pre) / 2 + 32768;
                if v_m_acc < 0 then
                    s9_m_scaled <= to_unsigned(0, 16);
                elsif v_m_acc > 65535 then
                    s9_m_scaled <= to_unsigned(65535, 16);
                else
                    s9_m_scaled <= to_unsigned(v_m_acc, 16);
                end if;

                -- Stage 10: dx·M_scaled, dy·M_scaled
                s10_dx_m <= resize(side_pipe(12).dx * signed('0' & std_logic_vector(s9_m_scaled)), s10_dx_m'length);
                s10_dy_m <= resize(side_pipe(12).dy * signed('0' & std_logic_vector(s9_m_scaled)), s10_dy_m'length);

                -- Stage 10b: src_q15 = (DST_C << 15) + dx·M
                s10b_src_x_q15 <= to_signed((src_w_latched / 2) * 32768, s10b_src_x_q15'length) + s10_dx_m;
                s10b_src_y_q15 <= to_signed((src_h_latched / 2) * 32768, s10b_src_y_q15'length) + s10_dy_m;

                -- Stage 11: shift + clamp + warp_en mux. Now also extracts
                -- the 8-bit fractional parts (fx, fy) from the Q15 warped
                -- coordinates. Fractional is the bits between the integer
                -- (>>15) and the 8 LSB of frac — i.e. q15[14:7] interpreted
                -- as unsigned [0..256). For the identity / clamped paths
                -- the fractional is forced to 0 (no inter-pixel blend).
                v_src_x_q15 := to_integer(s10b_src_x_q15);
                v_src_y_q15 := to_integer(s10b_src_y_q15);
                v_src_x_pre := v_src_x_q15 / 32768;
                v_src_y_pre := v_src_y_q15 / 32768;
                -- Fractional extraction: take the abs(q15) low 15 bits and
                -- grab the upper 8. For negative q15 values we will clamp
                -- to 0 below anyway, so just force frac=0 in that case.
                if v_src_x_q15 < 0 then
                    v_fx_u := (others => '0');
                else
                    v_q15_pos_x := to_unsigned(v_src_x_q15, 31);
                    v_fx_u := v_q15_pos_x(14 downto 7);
                end if;
                if v_src_y_q15 < 0 then
                    v_fy_u := (others => '0');
                else
                    v_q15_pos_y := to_unsigned(v_src_y_q15, 31);
                    v_fy_u := v_q15_pos_y(14 downto 7);
                end if;
                if v_src_x_pre < 0 then
                    v_src_x_pre := 0;
                    v_fx_u := (others => '0');
                elsif v_src_x_pre >= src_w_latched - 1 then
                    -- saturate: can't bilerp past the last column either
                    v_src_x_pre := src_w_latched - 1;
                    v_fx_u := (others => '0');
                end if;
                if v_src_y_pre < 0 then
                    v_src_y_pre := 0;
                    v_fy_u := (others => '0');
                elsif v_src_y_pre >= src_h_latched - 1 then
                    v_src_y_pre := src_h_latched - 1;
                    v_fy_u := (others => '0');
                end if;
                -- Identity from side_pipe(14)
                if side_pipe(14).v_in_act = '1' then
                    v_src_x_id := side_pipe(14).cnt_x_o;
                    v_src_y_id := side_pipe(14).cnt_y_o;
                    if v_src_x_id >= src_w_latched then v_src_x_id := src_w_latched - 1; end if;
                    if v_src_y_id >= src_h_latched then v_src_y_id := src_h_latched - 1; end if;
                else
                    v_src_x_id := 0;
                    v_src_y_id := 0;
                end if;
                -- SHARP-BILINEAR: steepen the fraction about its midpoint
                -- (0.5 = 128) so it snaps toward 0 or 1 except a thin band.
                --   fx_sharp = clamp(SHARP_K*(fx-128) + 128, 0, 255)
                -- SHARP_K=1 leaves it pure bilinear; >1 sharpens toward NN.
                v_fxs_i := SHARP_K * (to_integer(v_fx_u) - 128) + 128;
                if    v_fxs_i < 0   then v_fx_s := (others => '0');
                elsif v_fxs_i > 255 then v_fx_s := (others => '1');
                else  v_fx_s := to_unsigned(v_fxs_i, 8); end if;
                v_fys_i := SHARP_K * (to_integer(v_fy_u) - 128) + 128;
                if    v_fys_i < 0   then v_fy_s := (others => '0');
                elsif v_fys_i > 255 then v_fy_s := (others => '1');
                else  v_fy_s := to_unsigned(v_fys_i, 8); end if;

                if side_pipe(14).warp_en = '1' then
                    s11_src_x <= v_src_x_pre;
                    s11_src_y <= v_src_y_pre;
                    s11_fx    <= v_fx_s;
                    s11_fy    <= v_fy_s;
                else
                    s11_src_x <= v_src_x_id;
                    s11_src_y <= v_src_y_id;
                    s11_fx    <= (others => '0');
                    s11_fy    <= (others => '0');
                end if;

                -- Stage 12: emit 4 bank read addresses (one per sub-bank).
                -- Strategy:
                --   floor = (s11_src_x, s11_src_y)          -- top-left of 2x2
                --   floor+1 in each axis (with clamp)       -- bottom-right
                --   half-col_lo = floor_x >> 1, half-row_lo = floor_y >> 1
                --   half-col_hi = (floor_x+1) >> 1, half-row_hi = (floor_y+1) >> 1
                --   parities determine which of the 4 banks gets which
                --   (lo, hi) half-column / half-row pair. Then we always
                --   produce ONE address per bank (so all 4 banks read
                --   simultaneously).
                -- v3.3b: clamp src_y to the BIDIRECTIONAL window around the
                -- DELAYED output line. Because the writer now leads the
                -- reader by ~N_LINES/2 lines, the buffer holds both ±N_LINES/2
                -- around cnt_y_o, so the warp can look forward AND backward.
                --   v_line_min := cnt_y_o - N_LINES/2 + 1   (floored at 0)
                --   v_line_max := cnt_y_o + N_LINES/2
                v_line_min := cnt_y_o - (N_LINES / 2) + 1;
                if v_line_min < 0 then
                    v_line_min := 0;
                end if;
                v_line_max := cnt_y_o + (N_LINES / 2);
                v_src_y_fin := s11_src_y;
                if v_src_y_fin > v_line_max then
                    v_src_y_fin := v_line_max;
                elsif v_src_y_fin < v_line_min then
                    v_src_y_fin := v_line_min;
                end if;
                v_src_x_fin := s11_src_x;
                if v_src_x_fin >= MAX_SRC_W then
                    v_src_x_fin := MAX_SRC_W - 1;
                end if;
                -- floor and floor+1, both clamped to the same legal range
                -- so a clamp at the right/bottom edge means floor+1 ==
                -- floor, which still reads from the legal bank (the bilerp
                -- weight on that neighbour is then irrelevant because fx/fy
                -- were forced to 0 in stage 11 for the saturating case).
                v_fx_lo := v_src_x_fin;
                v_fx_hi := v_src_x_fin + 1;
                if v_fx_hi > MAX_SRC_W - 1 then v_fx_hi := MAX_SRC_W - 1; end if;
                v_fy_lo := v_src_y_fin;
                v_fy_hi := v_src_y_fin + 1;
                -- Keep fy_hi within the sliding-window upper bound. The
                -- height clamp was already applied in stage 11 (src_y_pre <
                -- src_h_latched - 1). v3.3b: the ceiling is now the
                -- bidirectional window top (cnt_y_o + N_LINES/2), not the
                -- lockstep writer line.
                if v_fy_hi > v_line_max then v_fy_hi := v_line_max; end if;
                -- Parities
                if (v_fx_lo mod 2) = 1 then v_x_lo_p := '1'; else v_x_lo_p := '0'; end if;
                if (v_fx_hi mod 2) = 1 then v_x_hi_p := '1'; else v_x_hi_p := '0'; end if;
                if (v_fy_lo mod 2) = 1 then v_y_lo_p := '1'; else v_y_lo_p := '0'; end if;
                if (v_fy_hi mod 2) = 1 then v_y_hi_p := '1'; else v_y_hi_p := '0'; end if;
                -- Half coords (within-bank linear index = half_row * HALF_W + half_col,
                -- with half_row taken mod N_HLINES to give sliding-window behaviour).
                v_x_lo_h := v_fx_lo / 2;
                v_x_hi_h := v_fx_hi / 2;
                v_y_lo_h := (v_fy_lo / 2) mod N_HLINES;
                v_y_hi_h := (v_fy_hi / 2) mod N_HLINES;
                -- For each of the 4 banks, pick the (half_col, half_row)
                -- combination whose parities match. Because (x_lo_p, x_hi_p)
                -- partition the two x-parity buckets and (y_lo_p, y_hi_p)
                -- partition the two y-parity buckets, exactly one of the
                -- 4 (x, y) pairings maps to each bank.
                if v_x_lo_p = '0' then
                    -- x_lo is the EVEN-x source, x_hi is the ODD-x source.
                    if v_y_lo_p = '0' then
                        v_a_ee := v_y_lo_h * HALF_W + v_x_lo_h;
                        v_a_eo := v_y_lo_h * HALF_W + v_x_hi_h;
                        v_a_oe := v_y_hi_h * HALF_W + v_x_lo_h;
                        v_a_oo := v_y_hi_h * HALF_W + v_x_hi_h;
                    else
                        v_a_ee := v_y_hi_h * HALF_W + v_x_lo_h;
                        v_a_eo := v_y_hi_h * HALF_W + v_x_hi_h;
                        v_a_oe := v_y_lo_h * HALF_W + v_x_lo_h;
                        v_a_oo := v_y_lo_h * HALF_W + v_x_hi_h;
                    end if;
                else
                    -- x_lo is the ODD-x source, x_hi is the EVEN-x source.
                    if v_y_lo_p = '0' then
                        v_a_ee := v_y_lo_h * HALF_W + v_x_hi_h;
                        v_a_eo := v_y_lo_h * HALF_W + v_x_lo_h;
                        v_a_oe := v_y_hi_h * HALF_W + v_x_hi_h;
                        v_a_oo := v_y_hi_h * HALF_W + v_x_lo_h;
                    else
                        v_a_ee := v_y_hi_h * HALF_W + v_x_hi_h;
                        v_a_eo := v_y_hi_h * HALF_W + v_x_lo_h;
                        v_a_oe := v_y_lo_h * HALF_W + v_x_hi_h;
                        v_a_oo := v_y_lo_h * HALF_W + v_x_lo_h;
                    end if;
                end if;
                s12_addr_ee <= v_a_ee;
                s12_addr_eo <= v_a_eo;
                s12_addr_oe <= v_a_oe;
                s12_addr_oo <= v_a_oo;
                s12_fx  <= s11_fx;
                s12_fy  <= s11_fy;
                s12_fxp <= v_x_lo_p;
                s12_fyp <= v_y_lo_p;
                s12_hs <= side_pipe(N_WARP_STAGES).hs;
                s12_vs <= side_pipe(N_WARP_STAGES).vs;
                s12_de <= side_pipe(N_WARP_STAGES).de;
                s12_bilinear <= bilinear_en;

                -- Stage 13: route bank reads to (p00, p01, p10, p11) based
                -- on floor parities, and carry fx/fy/sync/bilinear_en. The
                -- raw bank outputs (s13_q_*) come from the pixel-bank
                -- single-process block below.
                --
                -- p00 = pixel at (floor_x,   floor_y)
                -- p01 = pixel at (floor_x+1, floor_y)
                -- p10 = pixel at (floor_x,   floor_y+1)
                -- p11 = pixel at (floor_x+1, floor_y+1)
                --
                -- The bank for each is determined by the parity bits
                -- s12_fxp (=floor_x[0]) and s12_fyp (=floor_y[0]).
                v_parity_sel := s12_fyp & s12_fxp;
                case v_parity_sel is
                    when "00" =>
                        -- floor parity (even, even)
                        s13_p00 <= s13_q_ee;
                        s13_p01 <= s13_q_eo;
                        s13_p10 <= s13_q_oe;
                        s13_p11 <= s13_q_oo;
                    when "01" =>
                        -- floor parity (even-y, odd-x)
                        s13_p00 <= s13_q_eo;
                        s13_p01 <= s13_q_ee;
                        s13_p10 <= s13_q_oo;
                        s13_p11 <= s13_q_oe;
                    when "10" =>
                        -- floor parity (odd-y, even-x)
                        s13_p00 <= s13_q_oe;
                        s13_p01 <= s13_q_oo;
                        s13_p10 <= s13_q_ee;
                        s13_p11 <= s13_q_eo;
                    when others =>  -- "11"
                        -- floor parity (odd, odd)
                        s13_p00 <= s13_q_oo;
                        s13_p01 <= s13_q_oe;
                        s13_p10 <= s13_q_eo;
                        s13_p11 <= s13_q_ee;
                end case;
                s13_fx    <= s12_fx;
                s13_fy    <= s12_fy;
                s13_hs    <= s12_hs;
                s13_vs    <= s12_vs;
                s13_de    <= s12_de;
                s13_bilinear <= s12_bilinear;

                -- Stage 14: horizontal lerp.
                v_one_minus_fx := to_unsigned(256, 9) - resize(s13_fx, 9);
                s14_top_r <= unsigned(s13_p00(23 downto 16)) * v_one_minus_fx
                           + unsigned(s13_p01(23 downto 16)) * resize(s13_fx, 9);
                s14_top_g <= unsigned(s13_p00(15 downto  8)) * v_one_minus_fx
                           + unsigned(s13_p01(15 downto  8)) * resize(s13_fx, 9);
                s14_top_b <= unsigned(s13_p00( 7 downto  0)) * v_one_minus_fx
                           + unsigned(s13_p01( 7 downto  0)) * resize(s13_fx, 9);
                s14_bot_r <= unsigned(s13_p10(23 downto 16)) * v_one_minus_fx
                           + unsigned(s13_p11(23 downto 16)) * resize(s13_fx, 9);
                s14_bot_g <= unsigned(s13_p10(15 downto  8)) * v_one_minus_fx
                           + unsigned(s13_p11(15 downto  8)) * resize(s13_fx, 9);
                s14_bot_b <= unsigned(s13_p10( 7 downto  0)) * v_one_minus_fx
                           + unsigned(s13_p11( 7 downto  0)) * resize(s13_fx, 9);
                s14_fy        <= s13_fy;
                s14_hs        <= s13_hs;
                s14_vs        <= s13_vs;
                s14_de        <= s13_de;
                s14_bilinear  <= s13_bilinear;
                s14_p00       <= s13_p00;

                -- Stage 15: vertical lerp.
                -- top_<c> and bot_<c> are sums of (8-bit pixel) * (9-bit weight)
                -- with the two weights summing to 256 → result is at most
                -- 255 * 256 = 65280 (fits in 16 bits, but we declared 17 for
                -- headroom). Multiplying by another 9-bit weight gives up to
                -- 65280 * 256 = ~16.7M → fits in 24 bits. We use 26-bit
                -- accumulators for the sum of two such products.
                v_one_minus_fy := to_unsigned(256, 9) - resize(s14_fy, 9);
                s15_r25 <= s14_top_r * v_one_minus_fy + s14_bot_r * resize(s14_fy, 9);
                s15_g25 <= s14_top_g * v_one_minus_fy + s14_bot_g * resize(s14_fy, 9);
                s15_b25 <= s14_top_b * v_one_minus_fy + s14_bot_b * resize(s14_fy, 9);
                s15_hs       <= s14_hs;
                s15_vs       <= s14_vs;
                s15_de       <= s14_de;
                s15_bilinear <= s14_bilinear;
                s15_p00      <= s14_p00;

                -- Stage 16: emit. Mux bilinear vs NN. Bilinear takes the
                -- top 8 bits of each channel's 26-bit accumulator (i.e.
                -- the [23:16] slice — equivalent to >>16 after the two
                -- 8-bit weight multiplies).
                if s15_bilinear = '1' then
                    s16_pixel <= std_logic_vector(s15_r25(23 downto 16))
                               & std_logic_vector(s15_g25(23 downto 16))
                               & std_logic_vector(s15_b25(23 downto 16));
                else
                    s16_pixel <= s15_p00;
                end if;
                s16_hs <= s15_hs;
                s16_vs <= s15_vs;
                s16_de <= s15_de;
            end if;
        end if;
    end process;

    -- ============================================================
    -- Pixel banks (4-way split for single-cycle bilinear fetch)
    -- ============================================================
    -- Each of the 4 banks gets its OWN process with one write port and one
    -- read port — Quartus's canonical simple-dual-port-RAM template. The
    -- write enable for each bank is gated on the (cnt_y_w[0], cnt_x_w[0])
    -- parities so each incoming pixel writes to exactly one bank.
    --
    -- Within-bank write address:
    --   wr_addr = ((cnt_y_w / 2) mod N_HLINES) * HALF_W + (cnt_x_w / 2)
    --
    -- Read address comes from stage 12 per bank (s12_addr_*). Read data
    -- registers into s13_q_* (1-cycle M10K read latency).
    --
    -- v3.3b: the WRITE port stays in the input domain (gated on ce_pix,
    -- cnt_y_w/cnt_x_w parities — UNCHANGED). The READ port moves to the
    -- DELAYED domain (gated on ce_pix_dly) so the popped read data aligns
    -- with the stage-13 muxer, which now runs on ce_pix_dly. Independent
    -- write/read clock-enables are still a clean simple-dual-port → M9K.
    -- Read-during-write of the same address is a non-issue here: the
    -- writer leads the reader by ~N_LINES/2 lines, so the read half-row is
    -- never the half-row being written this cycle.
    -- ============================================================

    -- Bank pb_ee: y even, x even
    process(clk)
        variable v_wr_addr : integer range 0 to BANK_DEPTH - 1;
    begin
        if rising_edge(clk) then
            -- WRITE port (input domain — unchanged)
            if ce_pix = '1' then
                if de_in = '1' and vs_rising = '0' and de_falling = '0'
                   and cnt_x_w < MAX_SRC_W
                   and (cnt_y_w mod 2) = 0 and (cnt_x_w mod 2) = 0 then
                    v_wr_addr := ((cnt_y_w / 2) mod N_HLINES) * HALF_W
                               + (cnt_x_w / 2);
                    pb_ee(v_wr_addr) <= r_in & g_in & b_in;
                end if;
            end if;
            -- READ port (delayed domain — aligns with stage 13 muxer)
            if ce_pix_dly = '1' then
                s13_q_ee <= pb_ee(s12_addr_ee);
            end if;
        end if;
    end process;

    -- Bank pb_eo: y even, x odd
    process(clk)
        variable v_wr_addr : integer range 0 to BANK_DEPTH - 1;
    begin
        if rising_edge(clk) then
            -- WRITE port (input domain — unchanged)
            if ce_pix = '1' then
                if de_in = '1' and vs_rising = '0' and de_falling = '0'
                   and cnt_x_w < MAX_SRC_W
                   and (cnt_y_w mod 2) = 0 and (cnt_x_w mod 2) = 1 then
                    v_wr_addr := ((cnt_y_w / 2) mod N_HLINES) * HALF_W
                               + (cnt_x_w / 2);
                    pb_eo(v_wr_addr) <= r_in & g_in & b_in;
                end if;
            end if;
            -- READ port (delayed domain — aligns with stage 13 muxer)
            if ce_pix_dly = '1' then
                s13_q_eo <= pb_eo(s12_addr_eo);
            end if;
        end if;
    end process;

    -- Bank pb_oe: y odd, x even
    process(clk)
        variable v_wr_addr : integer range 0 to BANK_DEPTH - 1;
    begin
        if rising_edge(clk) then
            -- WRITE port (input domain — unchanged)
            if ce_pix = '1' then
                if de_in = '1' and vs_rising = '0' and de_falling = '0'
                   and cnt_x_w < MAX_SRC_W
                   and (cnt_y_w mod 2) = 1 and (cnt_x_w mod 2) = 0 then
                    v_wr_addr := ((cnt_y_w / 2) mod N_HLINES) * HALF_W
                               + (cnt_x_w / 2);
                    pb_oe(v_wr_addr) <= r_in & g_in & b_in;
                end if;
            end if;
            -- READ port (delayed domain — aligns with stage 13 muxer)
            if ce_pix_dly = '1' then
                s13_q_oe <= pb_oe(s12_addr_oe);
            end if;
        end if;
    end process;

    -- Bank pb_oo: y odd, x odd
    process(clk)
        variable v_wr_addr : integer range 0 to BANK_DEPTH - 1;
    begin
        if rising_edge(clk) then
            -- WRITE port (input domain — unchanged)
            if ce_pix = '1' then
                if de_in = '1' and vs_rising = '0' and de_falling = '0'
                   and cnt_x_w < MAX_SRC_W
                   and (cnt_y_w mod 2) = 1 and (cnt_x_w mod 2) = 1 then
                    v_wr_addr := ((cnt_y_w / 2) mod N_HLINES) * HALF_W
                               + (cnt_x_w / 2);
                    pb_oo(v_wr_addr) <= r_in & g_in & b_in;
                end if;
            end if;
            -- READ port (delayed domain — aligns with stage 13 muxer)
            if ce_pix_dly = '1' then
                s13_q_oo <= pb_oo(s12_addr_oo);
            end if;
        end if;
    end process;

    -- s13_pixel: legacy NN signal kept only for SignalTap traceability.
    -- Driven combinationally from the s13_p00 mux output.
    s13_pixel <= s13_p00;

    -- ============================================================
    -- Output emitter: drive r/g/b/hs/vs/de from stage-16 registers
    -- (v3.1: s16 is the bilinear-or-NN muxed pixel; sync carries through
    -- s13 → s14 → s15 → s16 alongside the pixel data so all four arrive
    -- aligned). Black-out (output 0) when de='0'.
    -- ============================================================
    -- Real warp emitter restored 2026-05-28 (force-red diagnostic served
    -- its purpose: proved SITE C output reaches ASCAL on non-rotated cores).
    -- v3.3b: gated on ce_pix_dly so the output register advances in lockstep
    -- with the s16_* pipeline tail (which now runs in the delayed domain) and
    -- the FIFO-popped output sync. NOTE: downstream ASCAL must be clocked by
    -- the same delayed pixel-enable (ce_pix_dly) — a sys_top wiring concern.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                r_out  <= (others => '0');
                g_out  <= (others => '0');
                b_out  <= (others => '0');
                hs_out <= '0';
                vs_out <= '0';
                de_out <= '0';
            elsif ce_pix_dly = '1' then
                if s16_de = '1' then
                    r_out <= s16_pixel(23 downto 16);
                    g_out <= s16_pixel(15 downto 8);
                    b_out <= s16_pixel(7 downto 0);
                else
                    r_out <= (others => '0');
                    g_out <= (others => '0');
                    b_out <= (others => '0');
                end if;
                hs_out <= s16_hs;
                vs_out <= s16_vs;
                de_out <= s16_de;
            end if;
        end if;
    end process;

end architecture;
