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
--   - Read side: internal raster counter (cnt_x_o, cnt_y_o) walks
--     dst_w x dst_h, advancing 1 pixel per clock. Output hs/vs/de
--     regenerated from this counter (NOT delayed from input). For each
--     output pixel, src coord = identity (move 5b makes it warped).
--     A delay-line shift register carries (lane, hs, vs, de) so when
--     the read data arrives we know which 24-bit pixel lane to extract
--     and which sync state to emit alongside it.
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

    -- ---- Read side raster counter ----
    signal cnt_x_o      : integer := 0;
    signal cnt_y_o      : integer := 0;
    signal de_o_int     : std_logic := '0';
    signal hs_o_int     : std_logic := '0';
    signal vs_o_int     : std_logic := '0';

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
        m_scaled := resize(m_delta * signed('0' & std_logic_vector(k)), 21);
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
    vs_rising <= '1' when (vs_in = '1' and vs_in_d = '0') else '0';

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
    -- Read side: walk output raster, compute src coord, issue read,
    -- shift sync info through delay line.
    -- ============================================================
    process(clk)
        variable v_total_x : integer;
        variable v_total_y : integer;
        variable v_src_x   : integer;
        variable v_src_y   : integer;
        variable v_base    : integer;
        variable v_word    : integer;
        variable v_in_act  : boolean;
        -- Warp-math scratch vars
        variable v_dx, v_dy   : integer;
        variable v_dx2, v_dy2 : integer;
        variable v_r2         : integer;
        variable v_m_raw      : unsigned(15 downto 0);
        variable v_m_scaled   : unsigned(15 downto 0);
        variable v_dst_cx     : integer;
        variable v_dst_cy     : integer;
        variable v_sxq15      : integer;
        variable v_syq15      : integer;
        variable v_sxi, v_syi : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cnt_x_o   <= 0;
                cnt_y_o   <= 0;
                de_o_int  <= '0';
                hs_o_int  <= '0';
                vs_o_int  <= '0';
                pipe      <= (others => PIPE_ENTRY_ZERO);
                src_x_now <= 0;
                src_y_now <= 0;
                read_active <= '0';
                rd_word_addr <= 0;
            else
                v_total_x := to_integer(dst_w) + HBLANK;
                v_total_y := to_integer(dst_h) + VBLANK;

                if cnt_x_o = v_total_x - 1 then
                    cnt_x_o <= 0;
                    if cnt_y_o = v_total_y - 1 then
                        cnt_y_o <= 0;
                    else
                        cnt_y_o <= cnt_y_o + 1;
                    end if;
                else
                    cnt_x_o <= cnt_x_o + 1;
                end if;

                -- "In active area" for THIS cycle's counter value
                v_in_act := (cnt_x_o < to_integer(dst_w))
                            and (cnt_y_o < to_integer(dst_h));

                -- Sync regen (1-cycle registered)
                if v_in_act then
                    de_o_int <= '1';
                else
                    de_o_int <= '0';
                end if;
                if cnt_x_o = to_integer(dst_w) then
                    hs_o_int <= '1';
                else
                    hs_o_int <= '0';
                end if;
                if cnt_y_o = to_integer(dst_h) and cnt_x_o = 0 then
                    vs_o_int <= '1';
                elsif cnt_y_o = to_integer(dst_h) + 1 and cnt_x_o = 0 then
                    vs_o_int <= '0';
                end if;

                -- ---- Sampling: identity if warp_en=0, warped otherwise ----
                if v_in_act then
                    if warp_en = '1' then
                        v_dst_cx := to_integer(dst_w) / 2;
                        v_dst_cy := to_integer(dst_h) / 2;
                        v_dx := cnt_x_o - v_dst_cx;
                        v_dy := cnt_y_o - v_dst_cy;
                        v_dx2 := v_dx * v_dx;
                        v_dy2 := v_dy * v_dy;
                        v_r2 := LUT_AX2_Q24 * v_dx2 + LUT_AY2_Q24 * v_dy2;
                        if v_r2 < 0 then v_r2 := 0; end if;
                        v_m_raw    := warp_m_lookup(to_unsigned(v_r2, 32));
                        v_m_scaled := scale_m_by_curv(v_m_raw, curvature_k);
                        v_sxq15 := v_dst_cx * 32768
                                   + v_dx * to_integer(v_m_scaled);
                        v_syq15 := v_dst_cy * 32768
                                   + v_dy * to_integer(v_m_scaled);
                        v_sxi := v_sxq15 / 32768;
                        v_syi := v_syq15 / 32768;
                        if v_sxi < 0 then
                            v_sxi := 0;
                        elsif v_sxi >= to_integer(dst_w) then
                            v_sxi := to_integer(dst_w) - 1;
                        end if;
                        if v_syi < 0 then
                            v_syi := 0;
                        elsif v_syi >= to_integer(dst_h) then
                            v_syi := to_integer(dst_h) - 1;
                        end if;
                        v_src_x := v_sxi;
                        v_src_y := v_syi;
                    else
                        v_src_x := cnt_x_o;
                        v_src_y := cnt_y_o;
                    end if;
                else
                    v_src_x := 0;
                    v_src_y := 0;
                end if;
                src_x_now <= v_src_x;
                src_y_now <= v_src_y;

                -- Read address: read from the OPPOSITE bank from the
                -- writer (read drained = previous frame's writes).
                if bank_sel = '0' then
                    v_base := BANK_B_BASE;
                else
                    v_base := BANK_A_BASE;
                end if;
                v_word := v_base + v_src_y * STRIDE_WORDS
                          + (v_src_x / C_PIXELS_PER_WORD);
                rd_word_addr <= v_word;
                if v_in_act then
                    read_active <= '1';
                else
                    read_active <= '0';
                end if;

                -- Shift delay line. pipe(0) gets THIS cycle's sync/lane.
                -- pipe(0).rd_en is driven from v_in_act directly
                -- (combinational pre-T) — NOT from read_active (which
                -- is registered, lagging by 1 cycle). This keeps the
                -- pipe-tail entry aligned with the registered avl_read
                -- the mock will see one cycle later.
                for i in pipe'high downto 1 loop
                    pipe(i) <= pipe(i - 1);
                end loop;
                pipe(0).lane  <= v_src_x mod C_PIXELS_PER_WORD;
                if cnt_x_o = to_integer(dst_w) then
                    pipe(0).hs <= '1';
                else
                    pipe(0).hs <= '0';
                end if;
                if cnt_y_o = to_integer(dst_h) and cnt_x_o = 0 then
                    pipe(0).vs <= '1';
                else
                    pipe(0).vs <= '0';
                end if;
                if v_in_act then
                    pipe(0).de <= '1';
                else
                    pipe(0).de <= '0';
                end if;
                if v_in_act and (wr_pending = '0') then
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
