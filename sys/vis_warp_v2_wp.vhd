-- vis_warp_v2_wp -- "warp-as-parent" v2
--
-- Phase 2 architecture-reset (2026-05-26). Implements the new port
-- shape from `NOTES-vis-warp-v2-entity-sketch-2026-05-26.md`:
--
--   - Lives at site A (post-osd, pre-csync, clk_hdmi domain).
--   - Single clock; CDC FIFOs not needed in the streaming path.
--   - Inputs are HDMI-raster; outputs are HDMI-raster (no upscale).
--   - Runtime controls collapse to warp_en + curvature_k + dst_w/dst_h.
--
-- MOVE 5a (this revision): DDR3 ping-pong capture/readback with
-- identity sampling. The warp path is structurally present (the
-- read-side address generator can compute warped src coords) but the
-- math is stubbed at identity. Move 5b lights up the warp math.
--
-- Architecture:
--   - Write side: incoming pixels (din + ce_pix_in + de_in) get packed
--     4-at-a-time into 128-bit words and written to DDR3.
--   - Read side: cnt_x_o / cnt_y_o track INPUT pixel position, driven
--     from hs_in/vs_in/de_in edges (NOT a free-running counter). They
--     feed the warp math (dx = cnt_x - DST_CX, etc.) and the identity
--     src-coord path. For each input pixel, src coord = identity if
--     warp_en=0, else the barrel-warped coord from the v2 pipeline.
--     A delay-line shift register carries (lane, hs, vs, de) so when
--     the read data arrives we know which 24-bit pixel lane to extract
--     and which sync state to emit alongside it.
--   - Output sync (hs_out/vs_out/de_out) is delay-pass-through of
--     input sync. side_pipe(1).hs/vs/de are loaded from hs_in/vs_in/
--     de_in each cycle; they propagate through side_pipe + pipe to the
--     emitter unchanged. This means the upstream raster's REAL HDMI
--     blanking widths (~280 cycles HBLANK, ~45 lines VBLANK at 1080p)
--     are preserved end-to-end. The legacy HBLANK/VBLANK generics are
--     unused now; kept on the entity for wrapper-contract stability.
--     [bug-fix 2026-05-27: prior version regenerated sync from cnt_x_o
--     positions with hardcoded HBLANK=16/VBLANK=4 — totally wrong for
--     real HDMI, monitor refused to lock on hardware.]
--   - Bank ping-pong: vs_rising flips bank_sel. Writer fills bank_sel;
--     reader reads from the OTHER bank. Net latency: 1 frame.
--   - Single Avalon master internally: writes have priority. When a
--     write fires, the read for that cycle is skipped (pipe(0).rd_en=0),
--     so the emitter knows the matching cycle has no valid readdata
--     and emits black instead. Keep ce_pix_in sparse in TBs to bound
--     dropped reads.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.vis_warp_pkg_v2.all;
use work.vis_warp_luts_pkg.all;

entity vis_warp_v2_wp is
    generic (
        MAX_DST_W   : integer := 1920;
        MAX_DST_H   : integer := 1080;
        ARX         : integer := 4;
        ARY         : integer := 3;
        AW          : integer := 28;
        DW          : integer := 128;
        BEW         : integer := 16;
        BCW         : integer := 8;
        BANK_A_BASE : integer := 0;
        BANK_B_BASE : integer := 2_097_152;
        READ_LAT    : integer := 8;
        -- Output raster blanking. Defaults match common HDMI rasters
        -- conservatively; TB or wrapper can shrink for compact sims.
        HBLANK      : integer := 16;
        VBLANK      : integer := 4
    );
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;

        warp_en     : in  std_logic;
        curvature_k : in  unsigned(2 downto 0);

        dst_w       : in  unsigned(11 downto 0);
        dst_h       : in  unsigned(11 downto 0);

        ce_pix_in   : in  std_logic;
        din         : in  std_logic_vector(23 downto 0);
        hs_in       : in  std_logic;
        vs_in       : in  std_logic;
        de_in       : in  std_logic;

        ce_pix_out  : out std_logic;
        dout        : out std_logic_vector(23 downto 0);
        hs_out      : out std_logic;
        vs_out      : out std_logic;
        de_out      : out std_logic;

        avl_address       : out std_logic_vector(AW - 1 downto 0);
        avl_burstcount    : out std_logic_vector(BCW - 1 downto 0);
        avl_writedata     : out std_logic_vector(DW - 1 downto 0);
        avl_byteenable    : out std_logic_vector(BEW - 1 downto 0);
        avl_write         : out std_logic;
        avl_read          : out std_logic;
        avl_readdata      : in  std_logic_vector(DW - 1 downto 0);
        avl_readdatavalid : in  std_logic;
        avl_waitrequest   : in  std_logic
    );

    attribute keep    : boolean;
    attribute noprune : boolean;
    attribute keep    of warp_en     : signal is true;
    attribute noprune of warp_en     : signal is true;
    attribute keep    of curvature_k : signal is true;
    attribute noprune of curvature_k : signal is true;
end entity;

architecture rtl of vis_warp_v2_wp is

    constant STRIDE_WORDS : integer := (MAX_DST_W + C_PIXELS_PER_WORD - 1)
                                       / C_PIXELS_PER_WORD;
    constant ADDR_BYTE_SHIFT : integer := 4;   -- 16 bytes per 128-bit word

    -- ---- Bank ping-pong ----
    signal bank_sel   : std_logic := '0';
    signal vs_in_d    : std_logic := '0';
    signal vs_rising  : std_logic;

    -- ---- Write side state ----
    signal cnt_x_w      : integer range 0 to MAX_DST_W - 1 := 0;
    signal cnt_y_w      : integer range 0 to MAX_DST_H - 1 := 0;
    signal wr_pix_phase : integer range 0 to 3 := 0;
    signal wr_pix0      : std_logic_vector(23 downto 0) := (others => '0');
    signal wr_pix1      : std_logic_vector(23 downto 0) := (others => '0');
    signal wr_pix2      : std_logic_vector(23 downto 0) := (others => '0');
    signal wr_pending   : std_logic := '0';
    signal wr_addr_word : integer := 0;
    signal wr_data      : std_logic_vector(127 downto 0) := (others => '0');

    -- ---- Input-sync edge detect ----
    -- hs_in_d / de_in_d are 1-cycle delayed versions of the input sync.
    -- de_in falling edge = end of an active row -> advance cnt_y_o and
    -- reset cnt_x_o. (hs_in_d kept around in case future code needs
    -- hs_in rising for guidance; not strictly used yet.)
    signal hs_in_d      : std_logic := '0';
    signal de_in_d      : std_logic := '0';
    signal de_in_falling : std_logic;

    -- ---- Read side raster counter ----
    -- cnt_x_o / cnt_y_o track current INPUT pixel position. Driven from
    -- input sync, NOT a free-running counter. Feeds the warp math
    -- (dx = cnt_x_o - DST_CX, etc.) and the identity src lookup.
    signal cnt_x_o      : integer := 0;
    signal cnt_y_o      : integer := 0;

    -- Source coord for the read being issued THIS cycle
    signal src_x_now    : integer := 0;
    signal src_y_now    : integer := 0;
    -- read_reg: registered avl_read decision derived from the SAME
    -- pre-T v_in_act + wr_pending values as pipe(0).rd_en. Keeping them
    -- both registered from the same source eliminates the 1-cycle skew
    -- that previously dropped the first read of every active row.
    signal read_reg     : std_logic := '0';
    signal read_active  : std_logic := '0';
    signal rd_word_addr : integer := 0;

    -- ---- Read pipeline delay-line ----
    -- Depth = READ_LAT + 2 to align with the mock's effective latency.
    -- Trace: pipe(0) scheduled at edge T, post-T value visible at pre-T+1.
    -- Mock samples avl_read at pre-T+1 (= the registered read_reg from edge T).
    -- Mock's rd_pipe shifts READ_LAT times, then schedules readdatavalid on
    -- the next edge — so readdatavalid='1' visible at pre-T+READ_LAT+2.
    -- pipe(K) holds the entry at pre-T+K+1, so K = READ_LAT+1 aligns =>
    -- pipe depth indexes 0..READ_LAT+1 (= READ_LAT+2 total slots).
    type pipe_entry_t is record
        lane  : integer range 0 to 3;
        hs    : std_logic;
        vs    : std_logic;
        de    : std_logic;
        rd_en : std_logic;
    end record;
    type pipe_t is array (natural range <>) of pipe_entry_t;
    constant PIPE_ENTRY_ZERO : pipe_entry_t :=
        (lane => 0, hs => '0', vs => '0', de => '0', rd_en => '0');
    signal pipe : pipe_t(0 to READ_LAT + 1) := (others => PIPE_ENTRY_ZERO);

    -- Combinationally-derived "actual read fires this cycle" — used by
    -- both the pipe insertion (rd_en) and the Avalon master mux.
    signal read_fire : std_logic;

    -- ============================================================
    -- WARP PIPELINE (move 8 — timing closure on clk_hdmi)
    -- ============================================================
    -- The warp math was a single deep combinational chain in move 5b
    -- (~9 dependent multiplies + LUT + clamp). At HDMI pixel clock
    -- (~148.5 MHz, 6.7 ns period) that chain took ~66 ns → -59 ns
    -- setup slack in the FIT. Move 8 splits it into N_WARP_STAGES
    -- registered stages, each with ≤1 multiply, so each stage fits
    -- comfortably in one clk_hdmi period.
    --
    -- side_pipe carries position + sync state through the pipeline
    -- so that when the warp result emerges at stage N_WARP_STAGES,
    -- it can be paired with the *correct* output pixel's (de, hs, vs).
    -- s2..s11 are the live arithmetic outputs per stage.
    constant N_WARP_STAGES : integer := 16;

    type warp_side_t is record
        cnt_x_o  : integer range 0 to MAX_DST_W + 4095;  -- generous headroom
        cnt_y_o  : integer range 0 to MAX_DST_H + 4095;
        dx       : signed(15 downto 0);
        dy       : signed(15 downto 0);
        de       : std_logic;
        hs       : std_logic;
        vs       : std_logic;
        v_in_act : std_logic;
        warp_en  : std_logic;
        k        : unsigned(2 downto 0);
    end record;

    constant WARP_SIDE_ZERO : warp_side_t := (
        cnt_x_o => 0, cnt_y_o => 0,
        dx => (others => '0'), dy => (others => '0'),
        de => '0', hs => '0', vs => '0',
        v_in_act => '0', warp_en => '0',
        k => (others => '0')
    );

    type warp_side_pipe_t is array (1 to N_WARP_STAGES) of warp_side_t;
    signal side_pipe : warp_side_pipe_t := (others => WARP_SIDE_ZERO);

    -- Live arithmetic per stage. Each is the REGISTERED output of stage N,
    -- valid as input to stage N+1.
    -- Width-narrowing for DSP block fit: the realistic max under any
    -- sane dst dim (MAX_DST_W=1920 → dx max=960, dx² max ≈ 9.2e5) fits
    -- in 21 bits unsigned. signed(26:0) gives generous headroom while
    -- keeping the operand within Cyclone V's 27×27 DSP block (single
    -- block, no inter-block routing delay). Original signed(31:0) was
    -- forcing Quartus to span 2 DSPs which busted clk_hdmi by ~3 ns.
    signal s2_dx2, s2_dy2          : signed(26 downto 0) := (others => '0');
    -- AX2 ≤ 508 fits in signed(10:0). Product max ≈ 5e8 → signed(30:0).
    signal s3_ax2dx2, s3_ay2dy2    : signed(30 downto 0) := (others => '0');
    signal s4_r2                   : signed(31 downto 0) := (others => '0');
    signal s5_m_lo, s5_m_hi        : unsigned(15 downto 0) := (others => '0');
    signal s5_frac                 : unsigned(7 downto 0) := (others => '0');
    -- Stage 5b: buffer the ROM outputs through a flip-flop with normal
    -- clock-to-Q. The altsyncram block's PORT_A clock-to-Q (~5 ns) leaves
    -- no headroom for the sub+mul that follows; a single intervening
    -- register restores per-stage timing closure.
    signal s5b_m_lo, s5b_m_hi      : unsigned(15 downto 0) := (others => '0');
    signal s5b_frac                : unsigned(7 downto 0) := (others => '0');
    -- Stage 5c: separates the sub (m_hi - m_lo) from the mul (×frac).
    -- Combining them in one cycle put the path ~2 ns over budget.
    signal s5c_m_diff              : signed(16 downto 0) := (others => '0');
    signal s5c_m_lo                : unsigned(15 downto 0) := (others => '0');
    signal s5c_frac                : unsigned(7 downto 0) := (others => '0');
    signal s6_m_diff_frac          : signed(24 downto 0) := (others => '0');
    signal s6_m_lo                 : unsigned(15 downto 0) := (others => '0');
    signal s7_m_raw                : unsigned(15 downto 0) := (others => '0');
    -- Stage 7b: separate (m_raw - 32768) sub from the *K mul. Same
    -- "sub + mul in one cycle" pattern as 5c → 6.
    signal s7b_m_centered          : signed(17 downto 0) := (others => '0');
    signal s8_m_scaled_pre         : signed(20 downto 0) := (others => '0');
    signal s9_m_scaled             : unsigned(15 downto 0) := (others => '0');
    signal s10_dx_m, s10_dy_m      : signed(31 downto 0) := (others => '0');
    -- Stage 10b: split the (DST_C << 15) + dx*M add from the
    -- downstream shift+clamp+warp_en-mux chain. The combined version
    -- (~32-bit add + shift + 2 compares + 2 muxes) was just over budget.
    signal s10b_src_x_q15          : signed(31 downto 0) := (others => '0');
    signal s10b_src_y_q15          : signed(31 downto 0) := (others => '0');
    signal s11_src_x, s11_src_y    : integer range 0 to 4095 := 0;
    -- Stage 12: register the post-pipeline word-address computation
    -- (mul s11_src_y * STRIDE + bank + s11_src_x/4) so pipe(0) only
    -- has trivial register loads. The mul alone was ~0.5 ns over.
    signal s12_word_addr           : integer := 0;
    signal s12_lane                : integer range 0 to 3 := 0;

    -- ---- Warp helpers (used when warp_en='1') ----
    -- Lookup with linear interp. Returns M as Q1.15 unsigned.
    -- Salvaged from parked stage-3c work — concept is unchanged.
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

    -- Apply runtime curvature K (0..7) to LUT-interpolated M.
    -- Concept salvaged from parked wip-stage3c-rescue:
    --   K=0 -> identity (M=32768),  K=2 -> bit-exact LUT value,
    --   K>2 -> stronger curvature,  K<2 -> weaker.
    -- Formula: result = 32768 + ((m_raw - 32768) * K) / 2.
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
    -- vs edge detect + bank swap
    -- ============================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                vs_in_d  <= '0';
                bank_sel <= '0';
            else
                vs_in_d <= vs_in;
                if vs_in = '1' and vs_in_d = '0' then
                    bank_sel <= not bank_sel;
                end if;
            end if;
        end if;
    end process;
    vs_rising     <= '1' when (vs_in = '1' and vs_in_d = '0') else '0';
    de_in_falling <= '1' when (de_in = '0' and de_in_d = '1') else '0';

    -- ============================================================
    -- Write side: pack 4 pixels -> 128-bit word -> DDR3 write.
    -- ============================================================
    process(clk)
        variable v_word_addr : integer;
        variable v_base      : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cnt_x_w      <= 0;
                cnt_y_w      <= 0;
                wr_pix_phase <= 0;
                wr_pending   <= '0';
                wr_addr_word <= 0;
                wr_data      <= (others => '0');
                wr_pix0 <= (others => '0');
                wr_pix1 <= (others => '0');
                wr_pix2 <= (others => '0');
            else
                if vs_rising = '1' then
                    cnt_x_w      <= 0;
                    cnt_y_w      <= 0;
                    wr_pix_phase <= 0;
                elsif ce_pix_in = '1' and de_in = '1' then
                    case wr_pix_phase is
                        when 0 => wr_pix0 <= din;
                        when 1 => wr_pix1 <= din;
                        when 2 => wr_pix2 <= din;
                        when others => null;
                    end case;

                    if wr_pix_phase = 3 then
                        if bank_sel = '0' then
                            v_base := BANK_A_BASE;
                        else
                            v_base := BANK_B_BASE;
                        end if;
                        v_word_addr := v_base + cnt_y_w * STRIDE_WORDS
                                       + (cnt_x_w / C_PIXELS_PER_WORD);
                        wr_addr_word <= v_word_addr;
                        wr_data      <= pack_4pix(wr_pix0, wr_pix1, wr_pix2, din);
                        wr_pending   <= '1';
                        wr_pix_phase <= 0;
                    else
                        wr_pix_phase <= wr_pix_phase + 1;
                    end if;

                    -- Wrap on dst_w / dst_h (the LIVE frame dimensions),
                    -- not MAX. The MAX_DST_* generics size storage; the
                    -- counter walks the active frame.
                    if cnt_x_w = to_integer(dst_w) - 1 then
                        cnt_x_w <= 0;
                        if cnt_y_w = to_integer(dst_h) - 1 then
                            cnt_y_w <= 0;
                        else
                            cnt_y_w <= cnt_y_w + 1;
                        end if;
                    else
                        cnt_x_w <= cnt_x_w + 1;
                    end if;
                end if;

                if wr_pending = '1' and avl_waitrequest = '0' then
                    wr_pending <= '0';
                end if;
            end if;
        end if;
    end process;

    -- ============================================================
    -- Read side: walk output raster, compute src coord via the
    -- pipelined warp math, issue read, shift sync info through the
    -- DDR3 delay line.
    --
    -- Pipeline structure (11 stages, each ≤1 multiply or ROM read):
    --   S1: dx, dy = cnt_x_o/y - DST_CX/Y                     (subs)
    --   S2: dx² (mul), dy² (mul)                              [parallel]
    --   S3: AX2·dx² (mul), AY2·dy² (mul)                      [parallel]
    --   S4: r² = AX2·dx² + AY2·dy²                            (add)
    --   S5: m_lo, m_hi = LUT[idx], LUT[idx+1]; carry frac     (ROM)
    --   S5b: buffer m_lo, m_hi, frac through a regular FF     (FF only — see note above)
    --   S5c: m_diff = m_hi - m_lo; carry m_lo, frac           (sub only)
    --   S6: m_diff * frac; carry m_lo                          (mul)
    --   S7: m_raw = m_lo + (prod >> 8)                        (add+shift)
    --   S7b: m_centered = m_raw - 32768                       (sub only)
    --   S8: m_scaled_pre = m_centered * K                     (mul)
    --   S9: m_scaled = clamp(32768 + m_scaled_pre/2)          (add+clamp)
    --   S10: dx*m_scaled (mul), dy*m_scaled (mul)             [parallel]
    --   S10b: src_q15 = (DST_C << 15) + dx*M                  (add only)
    --   S11: src = clamp(src_q15 >> 15); warp_en mux          (shift+clamp+mux)
    --   S12: word_addr = bank + src_y*STRIDE + src_x/4; lane  (mul+add)
    -- After S12: pipe(0) registered from side_pipe(N_WARP_STAGES) + s12_*.
    -- ============================================================
    process(clk)
        variable v_in_act  : boolean;
        variable v_dst_cx  : integer;
        variable v_dst_cy  : integer;
        variable v_dx_int  : integer;
        variable v_dy_int  : integer;
        -- Stage 5 (LUT index) scratch
        variable v_idx     : integer range 0 to 256;
        variable v_frac    : unsigned(7 downto 0);
        -- Stage 6 scratch
        variable v_m_diff  : signed(16 downto 0);
        -- Stage 9 (m_scaled clamp) scratch
        variable v_m_acc   : integer;
        -- Stage 11 (src clamp + warp_en mux) scratch
        variable v_src_x_q15 : integer;
        variable v_src_y_q15 : integer;
        variable v_src_x_pre : integer;
        variable v_src_y_pre : integer;
        variable v_src_x_id  : integer;
        variable v_src_y_id  : integer;
        variable v_src_x_fin : integer;
        variable v_src_y_fin : integer;
        -- After S11: word addr + bank + lane
        variable v_base    : integer;
        variable v_word    : integer;
        variable v_lane    : integer range 0 to 3;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cnt_x_o   <= 0;
                cnt_y_o   <= 0;
                hs_in_d   <= '0';
                de_in_d   <= '0';
                pipe      <= (others => PIPE_ENTRY_ZERO);
                src_x_now <= 0;
                src_y_now <= 0;
                read_active <= '0';
                read_reg    <= '0';
                rd_word_addr <= 0;
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
                s12_word_addr <= 0; s12_lane <= 0;
            else
                -- ---- Input-sync edge registers ----
                hs_in_d <= hs_in;
                de_in_d <= de_in;

                -- ---- Input-driven raster counter ----
                -- vs rising  -> reset cnt_y_o (and cnt_x_o defensively).
                -- de falling -> end of an active row: cnt_x_o<=0; cnt_y_o++.
                -- de high    -> active pixel: cnt_x_o++.
                -- During hblank/vblank (de='0', no falling edge this cycle)
                -- both counters hold. cnt_x_o always reflects the position
                -- of the pixel being registered into side_pipe(1) THIS cycle.
                if vs_rising = '1' then
                    cnt_x_o <= 0;
                    cnt_y_o <= 0;
                elsif de_in_falling = '1' then
                    cnt_x_o <= 0;
                    cnt_y_o <= cnt_y_o + 1;
                elsif de_in = '1' then
                    cnt_x_o <= cnt_x_o + 1;
                end if;

                -- ---- Combinational at stage 1 input ----
                -- v_in_act now == de_in: an active input pixel is being
                -- registered into the pipeline. Read issuance downstream
                -- still gates on side_pipe(N).v_in_act (= de_in delayed).
                v_in_act := (de_in = '1');
                v_dst_cx := to_integer(dst_w) / 2;
                v_dst_cy := to_integer(dst_h) / 2;
                v_dx_int := cnt_x_o - v_dst_cx;
                v_dy_int := cnt_y_o - v_dst_cy;

                -- ====================================================
                -- WARP PIPELINE
                -- ====================================================

                -- Side data shifts through every cycle.
                for k in 2 to N_WARP_STAGES loop
                    side_pipe(k) <= side_pipe(k - 1);
                end loop;

                -- Stage 1 entry: register current cycle's raster + sync
                -- state. hs/vs/de are pass-through from input — they
                -- propagate through side_pipe + pipe to hs_out/vs_out/
                -- de_out unchanged, preserving the upstream HDMI raster's
                -- real blanking widths. v_in_act mirrors de_in for read
                -- gating downstream.
                side_pipe(1).cnt_x_o  <= cnt_x_o;
                side_pipe(1).cnt_y_o  <= cnt_y_o;
                side_pipe(1).dx       <= to_signed(v_dx_int, 16);
                side_pipe(1).dy       <= to_signed(v_dy_int, 16);
                side_pipe(1).de       <= de_in;
                side_pipe(1).hs       <= hs_in;
                side_pipe(1).vs       <= vs_in;
                side_pipe(1).v_in_act <= de_in;
                side_pipe(1).warp_en  <= warp_en;
                side_pipe(1).k        <= curvature_k;

                -- Stage 2: parallel multipliers for dx², dy².
                -- Resize narrows back to s2_*'length=27 (signed(26:0)).
                s2_dx2 <= resize(side_pipe(1).dx * side_pipe(1).dx, s2_dx2'length);
                s2_dy2 <= resize(side_pipe(1).dy * side_pipe(1).dy, s2_dy2'length);

                -- Stage 3: AX2·dx², AY2·dy². Narrowed s2_* + narrow AX2
                -- (≤508) keeps the product inside a single 27×27 DSP
                -- block, avoiding the multi-DSP carry chain that
                -- previously cost ~3 ns.
                s3_ax2dx2 <= resize(to_signed(LUT_AX2_Q24, 11) * s2_dx2, s3_ax2dx2'length);
                s3_ay2dy2 <= resize(to_signed(LUT_AY2_Q24, 11) * s2_dy2, s3_ay2dy2'length);

                -- Stage 4: sum into r².
                s4_r2 <= resize(s3_ax2dx2, s4_r2'length)
                       + resize(s3_ay2dy2, s4_r2'length);

                -- Stage 5: extract idx + frac from r²; LUT read.
                -- Saturate to 2²⁴ - 1 if r² would overflow the LUT range.
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

                -- Stage 5b: buffer ROM outputs through a normal FF so
                -- the sub in stage 5c starts from a register with
                -- standard clock-to-Q instead of altsyncram's ~5 ns.
                s5b_m_lo <= s5_m_lo;
                s5b_m_hi <= s5_m_hi;
                s5b_frac <= s5_frac;

                -- Stage 5c: separate the m_diff sub from the mul (which
                -- now lives in stage 6 alone). Combining them put the
                -- path ~2 ns over budget at clk_hdmi.
                s5c_m_diff <= signed('0' & std_logic_vector(s5b_m_hi))
                            - signed('0' & std_logic_vector(s5b_m_lo));
                s5c_m_lo   <= s5b_m_lo;
                s5c_frac   <= s5b_frac;

                -- Stage 6: m_diff * frac; carry m_lo.
                s6_m_diff_frac <= resize(
                    s5c_m_diff * signed('0' & std_logic_vector(s5c_frac)),
                    s6_m_diff_frac'length);
                s6_m_lo <= s5c_m_lo;

                -- Stage 7: m_raw = m_lo + (prod >> 8).
                s7_m_raw <= s6_m_lo + unsigned(s6_m_diff_frac(23 downto 8));

                -- Stage 7b: m_centered = m_raw - 32768 (sub only).
                s7b_m_centered <= resize(
                    signed('0' & std_logic_vector(s7_m_raw)) - to_signed(32768, 17),
                    s7b_m_centered'length);

                -- Stage 8: m_scaled_pre = m_centered * K.
                -- side_pipe index +3 vs the non-buffered version since
                -- 5b, 5c, and 7b added three cycles of pipeline depth.
                s8_m_scaled_pre <= resize(
                    s7b_m_centered * signed('0' & std_logic_vector(side_pipe(10).k)),
                    s8_m_scaled_pre'length);

                -- Stage 9: clamp(32768 + m_scaled_pre/2).
                v_m_acc := to_integer(s8_m_scaled_pre) / 2 + 32768;
                if v_m_acc < 0 then
                    s9_m_scaled <= to_unsigned(0, 16);
                elsif v_m_acc > 65535 then
                    s9_m_scaled <= to_unsigned(65535, 16);
                else
                    s9_m_scaled <= to_unsigned(v_m_acc, 16);
                end if;

                -- Stage 10: dx·M_scaled, dy·M_scaled.
                -- signed(15:0) * signed(16:0) = signed(33:0); explicit
                -- resize down to s10_dx_m'length=32 since the realistic
                -- max under any sane dst dim fits comfortably.
                -- side_pipe index +3 from non-buffered version.
                s10_dx_m <= resize(side_pipe(12).dx * signed('0' & std_logic_vector(s9_m_scaled)), s10_dx_m'length);
                s10_dy_m <= resize(side_pipe(12).dy * signed('0' & std_logic_vector(s9_m_scaled)), s10_dy_m'length);

                -- Stage 10b: register src_q15 = (DST_C << 15) + dx·M
                -- so stage 11 only has shift + clamp + mux work.
                s10b_src_x_q15 <= to_signed(v_dst_cx * 32768, s10b_src_x_q15'length) + s10_dx_m;
                s10b_src_y_q15 <= to_signed(v_dst_cy * 32768, s10b_src_y_q15'length) + s10_dy_m;

                -- Stage 11: shift + clamp + warp_en mux.
                v_src_x_q15 := to_integer(s10b_src_x_q15);
                v_src_y_q15 := to_integer(s10b_src_y_q15);
                v_src_x_pre := v_src_x_q15 / 32768;
                v_src_y_pre := v_src_y_q15 / 32768;
                if v_src_x_pre < 0 then
                    v_src_x_pre := 0;
                elsif v_src_x_pre >= to_integer(dst_w) then
                    v_src_x_pre := to_integer(dst_w) - 1;
                end if;
                if v_src_y_pre < 0 then
                    v_src_y_pre := 0;
                elsif v_src_y_pre >= to_integer(dst_h) then
                    v_src_y_pre := to_integer(dst_h) - 1;
                end if;
                -- Identity: carry of cnt_x_o/y from 14 cycles ago,
                -- clamped to active raster when v_in_act was true at
                -- that cycle.
                if side_pipe(14).v_in_act = '1' then
                    v_src_x_id := side_pipe(14).cnt_x_o;
                    v_src_y_id := side_pipe(14).cnt_y_o;
                    if v_src_x_id >= to_integer(dst_w) then v_src_x_id := to_integer(dst_w) - 1; end if;
                    if v_src_y_id >= to_integer(dst_h) then v_src_y_id := to_integer(dst_h) - 1; end if;
                else
                    v_src_x_id := 0;
                    v_src_y_id := 0;
                end if;
                if side_pipe(14).warp_en = '1' then
                    s11_src_x <= v_src_x_pre;
                    s11_src_y <= v_src_y_pre;
                else
                    s11_src_x <= v_src_x_id;
                    s11_src_y <= v_src_y_id;
                end if;

                -- ====================================================
                -- Stage 12: word_addr + lane (registered).
                -- Bank_sel is stable for entire frames so reading it
                -- "current" vs side_pipe-aligned is fine in practice.
                -- ====================================================
                if bank_sel = '0' then
                    v_base := BANK_B_BASE;
                else
                    v_base := BANK_A_BASE;
                end if;
                s12_word_addr <= v_base + s11_src_y * STRIDE_WORDS
                                 + (s11_src_x / C_PIXELS_PER_WORD);
                s12_lane <= s11_src_x mod C_PIXELS_PER_WORD;
                src_x_now <= s11_src_x;
                src_y_now <= s11_src_y;
                read_active <= side_pipe(N_WARP_STAGES - 1).v_in_act;

                -- ====================================================
                -- After warp pipeline + word_addr stage: feed pipe(0).
                -- side_pipe(N_WARP_STAGES) is one cycle further than
                -- s12_* (extra stage of pipeline for word_addr), so
                -- the indices align: both reflect cycle T-N_WARP_STAGES.
                -- ====================================================
                rd_word_addr <= s12_word_addr;

                -- Shift the DDR3-alignment pipe (unchanged from move 5a).
                for i in pipe'high downto 1 loop
                    pipe(i) <= pipe(i - 1);
                end loop;
                pipe(0).lane <= s12_lane;
                pipe(0).hs   <= side_pipe(N_WARP_STAGES).hs;
                pipe(0).vs   <= side_pipe(N_WARP_STAGES).vs;
                pipe(0).de   <= side_pipe(N_WARP_STAGES).de;
                if side_pipe(N_WARP_STAGES).v_in_act = '1' and (wr_pending = '0') then
                    pipe(0).rd_en <= '1';
                    read_reg      <= '1';
                else
                    pipe(0).rd_en <= '0';
                    read_reg      <= '0';
                end if;
            end if;
        end if;
    end process;

    -- ============================================================
    -- Avalon master arbitration: writes have priority. Pure
    -- concurrent (combinational) muxing of the master signals so a
    -- write that fires this cycle preempts the read.
    -- ============================================================
    -- read_fire kept around for diagnostic naming; equals read_reg.
    read_fire <= read_reg;

    avl_address    <= std_logic_vector(
                          to_unsigned(wr_addr_word * (2 ** ADDR_BYTE_SHIFT), AW))
                      when wr_pending = '1'
                      else std_logic_vector(
                          to_unsigned(rd_word_addr * (2 ** ADDR_BYTE_SHIFT), AW));
    avl_burstcount <= std_logic_vector(to_unsigned(1, BCW));
    avl_write      <= wr_pending;
    avl_read       <= read_reg;
    avl_writedata  <= wr_data;
    avl_byteenable <= (others => '1');

    -- ============================================================
    -- Data emitter: align readdata with the pipe tail.
    -- ============================================================
    process(clk)
        variable v_lane : integer range 0 to 3;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                dout       <= (others => '0');
                de_out     <= '0';
                hs_out     <= '0';
                vs_out     <= '0';
                ce_pix_out <= '0';
            else
                if pipe(pipe'high).rd_en = '1' and avl_readdatavalid = '1' then
                    v_lane := pipe(pipe'high).lane;
                    dout       <= unpack_pix(avl_readdata, v_lane);
                    ce_pix_out <= '1';
                else
                    dout       <= (others => '0');
                    ce_pix_out <= '0';
                end if;
                de_out <= pipe(pipe'high).de;
                hs_out <= pipe(pipe'high).hs;
                vs_out <= pipe(pipe'high).vs;
            end if;
        end if;
    end process;

end architecture;
