-- vis_warp_v2 -- Phase 2 framework version: 24bpp, DDR3-backed
--
-- STAGE 3c of 4: warp LUT integration.
--
-- Adds barrel distortion via the Phase 1 warp LUT, applied at OUTPUT
-- (display) resolution:
--
--   When warp_en='0':
--     src_x_q15 = cnt_x_o * SRC_X_STEP_Q15   (linear Stage 3b walk)
--     src_y_q15 = cnt_y_o * SRC_Y_STEP_Q15
--
--   When warp_en='1':
--     dx = cnt_x_o - DST_CX                   (signed pixels)
--     dy = cnt_y_o - DST_CY
--     r2_norm = AX2_DST*dx^2 + AY2_DST*dy^2   (Q0.24; AX2/AY2 computed for DST dims)
--     M = WARP_LUT[idx_hi] + ((WARP_LUT[idx_hi+1] - WARP_LUT[idx_hi]) * frac) >> 8
--     dst_dx_warped_q15 = dx * M              (signed Q.15, in DST pixels)
--     dst_dy_warped_q15 = dy * M
--     src_x_q15 = SRC_CX_Q15 + (dst_dx_warped_q15 * SRC_W) / DST_W
--     src_y_q15 = SRC_CY_Q15 + (dst_dy_warped_q15 * SRC_H) / DST_H
--
-- Because warp is non-monotonic in src_y (barrel curves up at row extremes),
-- the 2-row cache from Stage 3b is too small. Stage 3c uses an N_CACHE=4
-- row cache with LRU-style eviction (replace the slot whose row is FURTHEST
-- from the currently-needed pair, when both needed rows aren't present).
--
-- AX2_DST / AY2_DST are computed at elaboration time from DST_W, DST_H,
-- and ARX/ARY generics (same physical aspect as Phase 1's hardcoded
-- 2880:2219 default, but parameterizable for non-Pac-Man cores).
--
-- Stage 4 will add bloom + scanlines in display space.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use work.vis_warp_pkg_v2.all;
use work.vis_warp_luts_pkg.all;

entity vis_warp_v2 is
    generic (
        SRC_W       : integer := 288;
        SRC_H       : integer := 224;
        DST_W       : integer := 288;
        DST_H       : integer := 224;
        -- Physical aspect ratio of the simulated CRT (used for AX2/AY2
        -- computation when warp_en='1'). Defaults to Pac-Man 4:3 cab.
        ARX         : integer := 2880;
        ARY         : integer := 2219;
        AW          : integer := 28;
        DW          : integer := 128;
        BEW         : integer := 16;
        BCW         : integer := 8;
        BANK_A_BASE : integer := 0;
        BANK_B_BASE : integer := 65536
    );
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;

        -- Runtime FX controls
        warp_en     : in  std_logic;
        -- Bloom (Stage 4a): 3x3 separable Gaussian + lerp/max-blend mix,
        -- applied in DST (display) space. Port shape matches Phase 1
        -- vis_warp + the firmware opcodes Agent C committed in
        -- Main_MiSTer-VIS @ be6cb79:
        --   bloom_en       : '1' enables the bloom pipeline. When '0',
        --                    bloom passes the warp/bilinear output
        --                    through unchanged (still 3 ce_pix latency).
        --   bloom_mode     : 0=Off/passthrough (rarely used; bloom_en=0
        --                    is the canonical disable), 1=lerp,
        --                    2=max-blend. Mirrors firmware's OSD
        --                    encoding: vis_warp_bloom_mode = {0,1,2}.
        --   bloom_mix_q8   : Q0.8 lerp mix factor (mode 1 only).
        --                    0=orig only .. 255=blur only.
        --                    Firmware currently leaves this at 0 — the
        --                    OSD doesn't expose a mix slider yet.
        --   bloom_gain     : Q0.4 blur gain for max-blend mode (mode 2).
        --                    halo = saturate((blur * gain + 8) >> 4).
        --                    Firmware payload uses vis_warp_bloom_gain
        --                    in 0..15.
        bloom_en       : in  std_logic;
        bloom_mode     : in  unsigned(1 downto 0);
        bloom_mix_q8   : in  unsigned(7 downto 0);
        bloom_gain     : in  unsigned(3 downto 0);
        -- Scanlines (Stage 4b): triangular brightness mod per OUTPUT row.
        -- Density selector chooses the period:
        --   00 (Off)    : passthrough, no modulation.
        --   01 (Light)  : period 8 output rows (log2 = 3, subtle).
        --   10 (Medium) : period 4 output rows (log2 = 2).
        --   11 (Heavy)  : period 2 output rows (log2 = 1, classic CRT).
        -- The LUT itself is fixed contrast (gap = 64/255 = 25%).
        scanlines      : in  unsigned(1 downto 0);

        -- Source
        ce_pix_in   : in  std_logic;
        din         : in  std_logic_vector(23 downto 0);
        hs_in       : in  std_logic;
        vs_in       : in  std_logic;
        de_in       : in  std_logic;

        -- Sink
        ce_pix_out  : out std_logic;
        dout        : out std_logic_vector(23 downto 0);
        hs_out      : out std_logic;
        vs_out      : out std_logic;
        de_out      : out std_logic;

        -- DDR3 (Avalon-MM)
        avl_address       : out std_logic_vector(AW - 1 downto 0);
        avl_burstcount    : out std_logic_vector(BCW - 1 downto 0);
        avl_writedata     : out std_logic_vector(DW - 1 downto 0);
        avl_byteenable    : out std_logic_vector(BEW - 1 downto 0);
        avl_write         : out std_logic;
        avl_read          : out std_logic;
        avl_readdata      : in  std_logic_vector(DW - 1 downto 0);
        avl_readdatavalid : in  std_logic;
        avl_waitrequest   : in  std_logic;

        -- Sim-only debug exports
        dbg_cnt_x_o : out integer;
        dbg_cnt_y_o : out integer
    );
end entity;

architecture rtl of vis_warp_v2 is

    constant STRIDE_WORDS : integer := (SRC_W + C_PIXELS_PER_WORD - 1) / C_PIXELS_PER_WORD;

    -- ---- Q15 step constants for incremental src_x walk (warp_en=0 case) ----
    constant SRC_X_STEP_Q15 : integer := (SRC_W * (2**15)) / DST_W;
    constant SRC_Y_STEP_Q15 : integer := (SRC_H * (2**15)) / DST_H;

    -- ---- Center coordinates ----
    constant DST_CX : integer := DST_W / 2;
    constant DST_CY : integer := DST_H / 2;
    constant SRC_CX_Q15 : integer := (SRC_W / 2) * (2**15);
    constant SRC_CY_Q15 : integer := (SRC_H / 2) * (2**15);

    -- ---- Aspect-corrected r2 weights for DST dims ----
    -- Mirrors warp_ref.py / gen_lut.py math, but for DST (not SRC).
    -- ax2_q24 = (phys_w^2) / phys_corner2 * 2^24
    -- ay2_q24 = (phys_h^2) / phys_corner2 * 2^24
    -- where phys_w = ARX/DST_W, phys_h = ARY/DST_H,
    -- phys_corner2 = (phys_w * DST_CX)^2 + (phys_h * DST_CY)^2.
    -- NB: Quartus 17.0 (Cyclone V Lite) rejects `real(2**24)` and
    -- `(real_val)**2` as ambiguous between universal_integer and
    -- integer overloads of "**". A's RTL uses ieee.math_real, which
    -- exposes a real-typed "**" via the standard.  We sidestep the
    -- ambiguity by (a) hoisting 2**24 to a real literal 16777216.0,
    -- and (b) rewriting x**2 as x*x. Behaviour is identical, both
    -- under Quartus and under GHDL --std=08.
    constant TWO_TO_24_REAL : real := 16777216.0;

    function compute_ax2 return integer is
        variable phys_w, phys_h, phys_corner2 : real;
        variable px, py : real;
    begin
        phys_w := real(ARX) / real(DST_W);
        phys_h := real(ARY) / real(DST_H);
        px := phys_w * real(DST_CX);
        py := phys_h * real(DST_CY);
        phys_corner2 := px*px + py*py;
        return integer(round( (phys_w*phys_w) / phys_corner2 * TWO_TO_24_REAL ));
    end function;
    function compute_ay2 return integer is
        variable phys_w, phys_h, phys_corner2 : real;
        variable px, py : real;
    begin
        phys_w := real(ARX) / real(DST_W);
        phys_h := real(ARY) / real(DST_H);
        px := phys_w * real(DST_CX);
        py := phys_h * real(DST_CY);
        phys_corner2 := px*px + py*py;
        return integer(round( (phys_h*phys_h) / phys_corner2 * TWO_TO_24_REAL ));
    end function;
    constant AX2_DST_Q24 : integer := compute_ax2;
    constant AY2_DST_Q24 : integer := compute_ay2;

    -- ---- Bank ping-pong ----
    signal bank_sel : std_logic := '0';
    signal vs_in_d  : std_logic := '0';
    signal vs_rising : std_logic;

    -- ---- Write side ----
    signal cnt_x_w : integer range 0 to SRC_W - 1 := 0;
    signal cnt_y_w : integer range 0 to SRC_H - 1 := 0;
    signal wr_pix0, wr_pix1, wr_pix2 : std_logic_vector(23 downto 0) := (others => '0');
    signal wr_pix_phase : integer range 0 to 3 := 0;
    signal wr_pending      : std_logic := '0';
    signal wr_pending_addr : integer := 0;
    signal wr_pending_data : std_logic_vector(127 downto 0) := (others => '0');

    -- ============================================================
    -- LINE CACHE (N_CACHE source rows for bilinear neighborhood + warp)
    -- ============================================================
    -- Stage 3b used 2 rows. Stage 3c needs more because warp can jump
    -- around (non-monotonic src_y across an output row, and adjacent output
    -- rows may need different SRC spans). N_CACHE=4 gives slack with low
    -- M10K cost (4 * SRC_W * 24bpp = ~7 KBit per row at 288 wide).
    constant N_CACHE : integer := 4;
    type line_t is array (0 to SRC_W - 1) of std_logic_vector(23 downto 0);
    type cache_array_t is array (0 to N_CACHE - 1) of line_t;
    signal cache_data : cache_array_t := (others => (others => (others => '0')));
    type cache_row_t is array (0 to N_CACHE - 1) of integer range -1 to SRC_H;
    signal cache_row : cache_row_t := (others => -1);
    -- LRU tracking: lower = older. Updated on hit (set highest) and fill.
    type cache_lru_t is array (0 to N_CACHE - 1) of integer range 0 to N_CACHE - 1;
    signal cache_lru : cache_lru_t := (0, 1, 2, 3);

    -- ---- Cache-fill FSM ----
    type cf_state_t is (CF_IDLE, CF_ISSUING, CF_RECEIVING);
    signal cf_state         : cf_state_t := CF_IDLE;
    signal cf_target_row    : integer range 0 to SRC_H - 1 := 0;
    signal cf_target_slot   : integer range 0 to N_CACHE - 1 := 0;
    signal cf_chunks_issued : integer range 0 to STRIDE_WORDS := 0;
    signal cf_chunks_recv   : integer range 0 to STRIDE_WORDS := 0;
    signal cf_issue_pulse   : std_logic := '0';
    signal cf_issue_addr    : integer := 0;

    -- In-flight reads counter. Tracks the total number of reads issued to
    -- the DDR3 but not yet received via avl_readdatavalid. After a
    -- vs_rising invalidate, we MUST wait for any in-flight reads to drain
    -- before issuing the NEXT fill, otherwise the stale rdvs would land
    -- in the new fill's slot. The mock's READ_LAT=8 pipeline allows up
    -- to ~READ_LAT reads in flight; we size generously.
    constant PEND_MAX : integer := 32;  -- generous; real HW would tune
    signal inflight_reads : integer range 0 to PEND_MAX := 0;
    -- "must drain" count: after vs_rising, refuse to start a new fill
    -- until inflight_reads has reached 0.
    signal drain_pending : std_logic := '0';

    signal read_need_y  : integer range 0 to SRC_H := 0;
    signal read_need_y1 : integer range 0 to SRC_H := 0;
    signal read_active  : std_logic := '0';

    -- ============================================================
    -- READ-OUT PIPELINE
    -- ============================================================
    signal cnt_x_o : integer range 0 to DST_W - 1 := 0;
    signal cnt_y_o : integer range 0 to DST_H - 1 := 0;

    -- For warp_en=0 path: incremental Q15 src walk
    signal src_x_q15 : integer := 0;
    signal src_y_q15 : integer := 0;

    signal hs_in_d, vs_in_d2 : std_logic := '0';
    signal dout_int        : std_logic_vector(23 downto 0) := (others => '0');
    signal ce_pix_out_int  : std_logic := '0';
    signal de_out_int      : std_logic := '0';
    signal hs_out_gen      : std_logic := '0';
    signal vs_out_gen      : std_logic := '0';

    -- ============================================================
    -- STAGE 4a: Bloom pipeline (3x3 separable Gaussian)
    -- ============================================================
    -- Per emitted output pixel:
    --   bl_pix0 = current pre-bloom pixel (= dout_int when ce_pix_out_int='1')
    --   bl_pix1, bl_pix2 = previous 2 pre-bloom pixels (horizontal neighbours)
    --   h_blur = (bl_pix2 + 2*bl_pix1 + bl_pix0) >> 2  per channel
    --     centered on bl_pix1; emitted 1 ce_pix after bl_pix1 arrived.
    --   lb_prev1, lb_prev2 = h_blur of prev 1 and 2 output rows, read
    --     synchronously at the same x as the current h_blur being written.
    --   v_blur = (lb_prev2 + 2*lb_prev1 + h_blur) >> 2 per channel.
    --   mix    : per bloom_mode, lerp(orig, v_blur) or max(orig, halo).
    --
    -- Sync signals (ce_pix_out / de_out / hs_out / vs_out) are delayed by
    -- the bloom pipeline latency = 3 emit events (the horizontal blur
    -- center is 1 emit late; the vertical blur uses two row-stride
    -- buffers and emits aligned with h_blur output). Concretely we
    -- maintain a 3-deep emit-event shift register.
    --
    -- When bloom_en='0', the pipeline still runs at constant timing but
    -- the output is forced equal to the (delayed) orig pixel — bit-exact
    -- bypass.
    --
    -- Line buffers are DST_W deep, 24bpp. For DST_W=1920 worst case
    -- that's 2 * 1920 * 24 = ~92 Kbit, well within Cyclone-V M10K budget.
    type lb_t is array (0 to DST_W - 1) of std_logic_vector(23 downto 0);
    signal lb_prev1 : lb_t := (others => (others => '0'));
    signal lb_prev2 : lb_t := (others => (others => '0'));

    -- Horizontal blur registers: 3-tap shift register of pre-bloom px.
    signal bl_pix0 : std_logic_vector(23 downto 0) := (others => '0');
    signal bl_pix1 : std_logic_vector(23 downto 0) := (others => '0');
    signal bl_pix2 : std_logic_vector(23 downto 0) := (others => '0');

    -- Horizontal blur output (= 3-tap kernel applied to bl_pix2..0,
    -- centered on bl_pix1). Computed combinationally when an emit
    -- happens. Stored in line buffers and pipelined.
    signal h_blur_now : std_logic_vector(23 downto 0) := (others => '0');

    -- Pre-bloom emit address counters: cnt_x_b, cnt_y_b lag cnt_x_o /
    -- cnt_y_o by 1 emit event (bl_pix1 is the H-blur center).
    signal cnt_x_b : integer range 0 to DST_W - 1 := 0;
    signal cnt_y_b : integer range 0 to DST_H - 1 := 0;

    -- Output sync shift register: 3-deep emit history.
    -- Holds (ce, de, hs, vs, x, y, orig_pix) at each pipeline stage.
    -- Stage 0 = freshest (= warp/bilinear output stage)
    -- Stage 1 = h_blur emit (1 emit later)
    -- Stage 2 = v_blur / mix emit (2 emits later — the final output)
    signal ce_sh   : std_logic_vector(2 downto 0) := (others => '0');
    signal de_sh   : std_logic_vector(2 downto 0) := (others => '0');
    signal hs_sh   : std_logic_vector(2 downto 0) := (others => '0');
    signal vs_sh   : std_logic_vector(2 downto 0) := (others => '0');
    type pix_sh_t is array (0 to 2) of std_logic_vector(23 downto 0);
    signal orig_sh : pix_sh_t := (others => (others => '0'));
    -- Per-emit row index for the bloom output (= cnt_y_o delayed by 2).
    type y_sh_t is array (0 to 2) of integer range 0 to DST_H - 1;
    signal y_sh : y_sh_t := (others => 0);

    -- Final bloomed pixel output (post-mix).
    signal bloomed_pix : std_logic_vector(23 downto 0) := (others => '0');

    -- Final post-scanlines pixel.
    signal final_pix : std_logic_vector(23 downto 0) := (others => '0');

    -- Returns the cache slot index holding source row Y, or -1 if not cached.
    function find_cache_slot(y : integer; rows : cache_row_t) return integer is
    begin
        for i in 0 to N_CACHE - 1 loop
            if rows(i) = y then return i; end if;
        end loop;
        return -1;
    end function;

    -- 8-bit bilinear blend (Stage 3b, unchanged)
    function blend8(a, b, c, d : unsigned(7 downto 0);
                    fx, fy     : unsigned(9 downto 0)) return unsigned is
        constant ONE_Q10 : unsigned(10 downto 0) := to_unsigned(1024, 11);
        variable inv_fx : unsigned(10 downto 0);
        variable inv_fy : unsigned(10 downto 0);
        variable top_full, bot_full : unsigned(18 downto 0);
        variable top_r, bot_r : unsigned(7 downto 0);
        variable out_full : unsigned(18 downto 0);
        variable out_r   : unsigned(7 downto 0);
    begin
        inv_fx := ONE_Q10 - ('0' & fx);
        inv_fy := ONE_Q10 - ('0' & fy);
        top_full := resize(inv_fx * a + ('0' & fx) * b, top_full'length);
        top_r    := resize(shift_right(top_full + to_unsigned(512, top_full'length), 10), 8);
        bot_full := resize(inv_fx * c + ('0' & fx) * d, bot_full'length);
        bot_r    := resize(shift_right(bot_full + to_unsigned(512, bot_full'length), 10), 8);
        out_full := resize(inv_fy * top_r + ('0' & fy) * bot_r, out_full'length);
        out_r    := resize(shift_right(out_full + to_unsigned(512, out_full'length), 10), 8);
        return out_r;
    end function;

    -- ---- Warp helpers (used when warp_en='1') ----
    -- Lookup with linear interp. Returns M as Q1.15 unsigned.
    -- r2_q24 is the unsigned r2_norm in [0, 2^24].
    function warp_m_lookup(r2_q24 : unsigned(31 downto 0)) return unsigned is
        variable r2_sat : unsigned(23 downto 0);
        variable idx : integer range 0 to 255;
        variable frac : unsigned(7 downto 0);
        variable m_lo, m_hi : unsigned(15 downto 0);
        variable diff : signed(16 downto 0);
        variable prod : signed(25 downto 0);
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

begin

    vs_rising <= '1' when vs_in = '1' and vs_in_d = '0' else '0';

    -- ============================================================
    -- Bank swap on vs rising
    -- ============================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                bank_sel <= '0';
                vs_in_d  <= '0';
            else
                vs_in_d <= vs_in;
                if vs_in = '1' and vs_in_d = '0' then
                    bank_sel <= not bank_sel;
                end if;
            end if;
        end if;
    end process;

    -- ============================================================
    -- Write side (unchanged from stage 3b)
    -- ============================================================
    process(clk)
        variable v_addr_word : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cnt_x_w <= 0; cnt_y_w <= 0;
                wr_pix_phase <= 0; wr_pending <= '0';
            else
                if vs_rising = '1' then
                    cnt_x_w <= 0; cnt_y_w <= 0; wr_pix_phase <= 0;
                elsif ce_pix_in = '1' and de_in = '1' then
                    case wr_pix_phase is
                        when 0 => wr_pix0 <= din;
                        when 1 => wr_pix1 <= din;
                        when 2 => wr_pix2 <= din;
                        when others => null;
                    end case;

                    if wr_pix_phase = 3 then
                        if bank_sel = '0' then
                            v_addr_word := BANK_A_BASE + cnt_y_w * STRIDE_WORDS + (cnt_x_w / 4);
                        else
                            v_addr_word := BANK_B_BASE + cnt_y_w * STRIDE_WORDS + (cnt_x_w / 4);
                        end if;
                        wr_pending_addr <= v_addr_word;
                        wr_pending_data <= pack_4pix(wr_pix0, wr_pix1, wr_pix2, din);
                        wr_pending <= '1';
                        wr_pix_phase <= 0;
                        report "    WRITE: addr=" & integer'image(v_addr_word)
                            -- to_hstring(wr_pix0) replaced for Quartus 17.0
                            -- compatibility -- 17.0 lacks VHDL-2008 hex
                            -- formatters on std_logic_vector. Show as int.
                            & " data_pix0=0x"
                            & integer'image(to_integer(unsigned(wr_pix0)))
                            & " bank_sel=" & std_logic'image(bank_sel);
                    else
                        wr_pix_phase <= wr_pix_phase + 1;
                    end if;

                    if cnt_x_w = SRC_W - 1 then
                        cnt_x_w <= 0;
                        if cnt_y_w = SRC_H - 1 then cnt_y_w <= 0;
                        else cnt_y_w <= cnt_y_w + 1; end if;
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
    -- Cache-fill FSM (demand-paged, N_CACHE slots, LRU eviction)
    --
    -- Same logic as Stage 3b but extended to N slots. Eviction picks the
    -- slot whose row is FURTHEST from the currently-needed pair (rough LRU
    -- approximation using slot ages).
    -- ============================================================
    process(clk)
        variable v_addr_word     : integer;
        variable v_slot_addr     : integer;
        variable v_word_in_row   : integer;
        variable v_need_y, v_need_y1 : integer;
        variable v_have_y, v_have_y1 : boolean;
        variable v_target_row    : integer;
        variable v_target_slot   : integer;
        variable v_evict_slot    : integer;
        variable v_can_advance   : boolean;
        variable v_have_empty    : boolean;
        variable v_empty_slot    : integer;
        variable v_evict_max_dist : integer;
        variable v_evict_dist     : integer;
        variable v_dist_to_y      : integer;
        variable v_dist_to_y1     : integer;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                for i in 0 to N_CACHE - 1 loop
                    cache_row(i) <= -1;
                    cache_lru(i) <= i;
                end loop;
                cf_state <= CF_IDLE;
                cf_target_row <= 0;
                cf_target_slot <= 0;
                cf_chunks_issued <= 0;
                cf_chunks_recv <= 0;
                cf_issue_pulse <= '0';
                inflight_reads <= 0;
                drain_pending <= '0';
            else
                cf_issue_pulse <= '0';

                -- ---- Read-data-valid handling (top-level, runs every
                -- ---- cycle independent of vs_rising). The drain
                -- ---- semantics ensure stale rdvs after a vs_rising
                -- ---- invalidate don't pollute the cache. ----
                if avl_readdatavalid = '1' then
                    if inflight_reads > 0 then
                        inflight_reads <= inflight_reads - 1;
                        if inflight_reads = 1 and drain_pending = '1' then
                            drain_pending <= '0';
                        end if;
                    end if;
                    if drain_pending = '1' then
                        -- Discard stale rdv from prior fill.
                        null;
                    elsif cf_state /= CF_IDLE
                          and cf_chunks_recv < STRIDE_WORDS then
                        v_word_in_row := cf_chunks_recv;
                        for lane in 0 to 3 loop
                            v_slot_addr := v_word_in_row * 4 + lane;
                            if v_slot_addr < SRC_W then
                                cache_data(cf_target_slot)(v_slot_addr)
                                    <= unpack_pix(avl_readdata, lane);
                            end if;
                        end loop;
                        cf_chunks_recv <= cf_chunks_recv + 1;
                    end if;
                end if;

                if vs_rising = '1' then
                    for i in 0 to N_CACHE - 1 loop
                        cache_row(i) <= -1;
                    end loop;
                    -- Set drain_pending if there are reads still in flight
                    -- AFTER accounting for the rdv (if any) just handled
                    -- above. The inflight_reads decrement is scheduled, so
                    -- the post-cycle value is (inflight_reads - 1) when
                    -- rdv fired, else (inflight_reads).
                    if (avl_readdatavalid = '1' and inflight_reads > 1)
                       or (avl_readdatavalid = '0' and inflight_reads > 0) then
                        drain_pending <= '1';
                    end if;
                    cf_state <= CF_IDLE;
                    cf_target_row <= 0;
                    cf_target_slot <= 0;
                    cf_chunks_issued <= 0;
                    cf_chunks_recv <= 0;
                    report "    CACHE: vs_rising invalidate; bank_sel was "
                        & std_logic'image(bank_sel);
                else
                    case cf_state is
                        when CF_IDLE =>
                            v_need_y  := read_need_y;
                            if read_need_y1 < SRC_H then
                                v_need_y1 := read_need_y1;
                            else
                                v_need_y1 := read_need_y;
                            end if;

                            v_have_y  := find_cache_slot(v_need_y,  cache_row) /= -1;
                            v_have_y1 := find_cache_slot(v_need_y1, cache_row) /= -1;

                            v_can_advance := false;
                            v_target_row  := 0;
                            v_target_slot := 0;

                            -- Block new fills while in-flight reads from a
                            -- prior (now-invalidated) request are still
                            -- draining.
                            if drain_pending = '0'
                               and read_active = '1' and v_need_y < SRC_H and not v_have_y then
                                v_target_row := v_need_y;
                                v_can_advance := true;
                            elsif drain_pending = '0'
                                  and read_active = '1' and v_need_y1 < SRC_H and not v_have_y1 then
                                v_target_row := v_need_y1;
                                v_can_advance := true;
                            end if;

                            -- Find an empty slot first; otherwise evict LRU
                            v_have_empty := false;
                            v_empty_slot := 0;
                            for i in 0 to N_CACHE - 1 loop
                                if cache_row(i) = -1 and not v_have_empty then
                                    v_empty_slot := i;
                                    v_have_empty := true;
                                end if;
                            end loop;

                            if v_can_advance then
                                if v_have_empty then
                                    v_target_slot := v_empty_slot;
                                else
                                    -- Evict slot whose row is FURTHEST from
                                    -- (v_need_y, v_need_y1). Pick the slot
                                    -- with max distance.
                                    v_evict_slot := 0;
                                    v_evict_max_dist := -1;
                                    for i in 0 to N_CACHE - 1 loop
                                        if cache_row(i) /= v_need_y
                                            and cache_row(i) /= v_need_y1 then
                                            v_dist_to_y := abs(cache_row(i) - v_need_y);
                                            v_dist_to_y1 := abs(cache_row(i) - v_need_y1);
                                            if v_dist_to_y > v_dist_to_y1 then
                                                v_evict_dist := v_dist_to_y;
                                            else
                                                v_evict_dist := v_dist_to_y1;
                                            end if;
                                            if v_evict_dist > v_evict_max_dist then
                                                v_evict_max_dist := v_evict_dist;
                                                v_evict_slot := i;
                                            end if;
                                        end if;
                                    end loop;
                                    cache_row(v_evict_slot) <= -1;
                                    v_can_advance := false;  -- pick empty next cycle
                                end if;
                            end if;

                            if v_can_advance then
                                cf_target_row    <= v_target_row;
                                cf_target_slot   <= v_target_slot;
                                cf_chunks_issued <= 0;
                                cf_chunks_recv   <= 0;
                                cf_state         <= CF_ISSUING;
                            end if;

                        when CF_ISSUING =>
                            if cf_chunks_issued < STRIDE_WORDS then
                                -- Defer issuing if a write is currently
                                -- occupying the bus, OR if a write will be
                                -- issued NEXT cycle (predicted from the
                                -- write process's own preconditions). The
                                -- two are independently necessary:
                                --   - wr_pending='1' now -> bus is busy
                                --     this cycle (avl_address muxed to
                                --     write addr).
                                --   - wr_pix_phase=3 AND ce_pix_in='1' AND
                                --     de_in='1' -> wr_pending goes '1' on
                                --     same edge our cf_issue_pulse goes
                                --     '1'; result: avl_read masked off and
                                --     the read is silently dropped.
                                if wr_pending = '0'
                                   and not (wr_pix_phase = 3
                                            and ce_pix_in = '1'
                                            and de_in = '1') then
                                    if bank_sel = '0' then
                                        v_addr_word := BANK_B_BASE + cf_target_row * STRIDE_WORDS + cf_chunks_issued;
                                    else
                                        v_addr_word := BANK_A_BASE + cf_target_row * STRIDE_WORDS + cf_chunks_issued;
                                    end if;
                                    cf_issue_addr <= v_addr_word;
                                    cf_issue_pulse <= '1';
                                    cf_chunks_issued <= cf_chunks_issued + 1;
                                    -- track issued reads (will be
                                    -- decremented on rdv arrival).
                                    inflight_reads <= inflight_reads + 1;
                                    report "    CACHE: issuing read addr="
                                        & integer'image(v_addr_word)
                                        & " slot=" & integer'image(cf_target_slot)
                                        & " row=" & integer'image(cf_target_row)
                                        & " bank_sel=" & std_logic'image(bank_sel);
                                end if;
                            else
                                cf_state <= CF_RECEIVING;
                            end if;

                        when CF_RECEIVING =>
                            if cf_chunks_recv >= STRIDE_WORDS then
                                cache_row(cf_target_slot) <= cf_target_row;
                                cf_state <= CF_IDLE;
                                report "    CACHE: fill done slot="
                                    & integer'image(cf_target_slot)
                                    & " row=" & integer'image(cf_target_row)
                                    & " data0=0x"
                                    & integer'image(to_integer(unsigned(cache_data(cf_target_slot)(0))));
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- ============================================================
    -- Read-out pipeline: emit one display pixel per ce_pix_in.
    -- Computes src coords (linear or warped), checks N-slot cache for the
    -- two rows needed (src_yi, src_yi+1), bilinearly blends 4 neighbors.
    -- ============================================================
    process(clk)
        variable v_dx, v_dy           : integer;
        variable v_dx_abs, v_dy_abs   : integer;
        variable v_dx2, v_dy2         : integer;
        variable v_r2                 : integer;
        variable v_m                  : integer;
        variable v_dst_dx_w_q15       : integer;  -- dst-space warped offset Q15
        variable v_dst_dy_w_q15       : integer;
        variable v_src_x_q15_now      : integer;
        variable v_src_y_q15_now      : integer;
        variable v_src_xi, v_src_yi   : integer;
        variable v_src_yi_p1          : integer;
        variable v_xa, v_xb           : integer range 0 to SRC_W - 1;
        variable v_fx_q10, v_fy_q10   : unsigned(9 downto 0);
        variable v_pix_tl, v_pix_tr   : std_logic_vector(23 downto 0);
        variable v_pix_bl, v_pix_br   : std_logic_vector(23 downto 0);
        variable v_out_r, v_out_g, v_out_b : unsigned(7 downto 0);
        variable v_slot_y, v_slot_y1  : integer;
        variable v_oob                : boolean;
        variable v_emit               : boolean;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cnt_x_o    <= 0; cnt_y_o <= 0;
                src_x_q15  <= 0; src_y_q15 <= 0;
                ce_pix_out_int <= '0';
                de_out_int <= '0';
                read_need_y  <= 0;
                read_need_y1 <= 0;
                read_active  <= '0';
            else
                ce_pix_out_int <= '0';
                de_out_int     <= '0';

                if vs_rising = '1' and read_active = '0' then
                    cnt_x_o    <= 0; cnt_y_o <= 0;
                    src_x_q15  <= 0; src_y_q15 <= 0;
                    read_need_y  <= 0;
                    read_need_y1 <= 1;
                    read_active  <= '1';
                end if;

                if ce_pix_in = '1' and read_active = '1' then
                    -- ---- 1. Compute src coords ----
                    if warp_en = '0' then
                        v_src_x_q15_now := src_x_q15;
                        v_src_y_q15_now := src_y_q15;
                    else
                        -- Warp pipeline (combinational; not pipelined for sim
                        -- simplicity. Real HW would pipeline these stages.)
                        v_dx := cnt_x_o - DST_CX;
                        v_dy := cnt_y_o - DST_CY;
                        if v_dx < 0 then v_dx_abs := -v_dx; else v_dx_abs := v_dx; end if;
                        if v_dy < 0 then v_dy_abs := -v_dy; else v_dy_abs := v_dy; end if;
                        v_dx2 := v_dx_abs * v_dx_abs;
                        v_dy2 := v_dy_abs * v_dy_abs;
                        v_r2  := AX2_DST_Q24 * v_dx2 + AY2_DST_Q24 * v_dy2;
                        v_m   := to_integer(warp_m_lookup(to_unsigned(v_r2, 32)));
                        v_dst_dx_w_q15 := v_dx * v_m;
                        v_dst_dy_w_q15 := v_dy * v_m;
                        -- Scale dst warped offset to src space:
                        --   src_offset_q15 = (dst_offset_q15 * SRC_W) / DST_W
                        v_src_x_q15_now := SRC_CX_Q15
                                          + (v_dst_dx_w_q15 * SRC_W) / DST_W;
                        v_src_y_q15_now := SRC_CY_Q15
                                          + (v_dst_dy_w_q15 * SRC_H) / DST_H;
                    end if;

                    v_src_xi := v_src_x_q15_now / (2**15);
                    v_src_yi := v_src_y_q15_now / (2**15);
                    v_src_yi_p1 := v_src_yi + 1;
                    v_fx_q10 := to_unsigned((v_src_x_q15_now / (2**5)) mod 1024, 10);
                    v_fy_q10 := to_unsigned((v_src_y_q15_now / (2**5)) mod 1024, 10);

                    v_oob := (v_src_xi < 0) or (v_src_xi >= SRC_W)
                          or (v_src_yi < 0) or (v_src_yi >= SRC_H);

                    -- ---- 2. Cache lookup (N-slot) ----
                    if v_oob then
                        v_slot_y  := -1;
                        v_slot_y1 := -1;
                    else
                        v_slot_y  := find_cache_slot(v_src_yi, cache_row);
                        if v_src_yi_p1 >= SRC_H then
                            v_slot_y1 := find_cache_slot(SRC_H - 1, cache_row);
                        else
                            v_slot_y1 := find_cache_slot(v_src_yi_p1, cache_row);
                        end if;
                    end if;

                    v_emit := false;
                    if v_oob then
                        v_emit := true;
                    elsif v_slot_y /= -1 and (v_fy_q10 = 0 or v_slot_y1 /= -1) then
                        v_emit := true;
                    end if;

                    if v_emit then
                        if v_slot_y1 >= 0 and cnt_y_o = 1 and cnt_x_o < 2 then
                            report "    READ DST(" & integer'image(cnt_x_o)
                                & "," & integer'image(cnt_y_o)
                                & ") src_yi=" & integer'image(v_src_yi)
                                & " fy=" & integer'image(to_integer(v_fy_q10))
                                & " sloty=" & integer'image(v_slot_y)
                                & " sloty1=" & integer'image(v_slot_y1)
                                & " cache_data(sloty1)(0)=0x"
                                & integer'image(to_integer(unsigned(cache_data(v_slot_y1)(0))));
                        end if;
                        if v_oob then
                            dout_int <= (others => '0');
                        else
                            v_xa := v_src_xi;
                            if v_src_xi + 1 < SRC_W then
                                v_xb := v_src_xi + 1;
                            else
                                v_xb := SRC_W - 1;
                            end if;

                            v_pix_tl := cache_data(v_slot_y)(v_xa);
                            v_pix_tr := cache_data(v_slot_y)(v_xb);
                            if v_fy_q10 = 0 then
                                v_pix_bl := v_pix_tl;
                                v_pix_br := v_pix_tr;
                            else
                                v_pix_bl := cache_data(v_slot_y1)(v_xa);
                                v_pix_br := cache_data(v_slot_y1)(v_xb);
                            end if;

                            v_out_r := blend8(unsigned(v_pix_tl(23 downto 16)),
                                              unsigned(v_pix_tr(23 downto 16)),
                                              unsigned(v_pix_bl(23 downto 16)),
                                              unsigned(v_pix_br(23 downto 16)),
                                              v_fx_q10, v_fy_q10);
                            v_out_g := blend8(unsigned(v_pix_tl(15 downto  8)),
                                              unsigned(v_pix_tr(15 downto  8)),
                                              unsigned(v_pix_bl(15 downto  8)),
                                              unsigned(v_pix_br(15 downto  8)),
                                              v_fx_q10, v_fy_q10);
                            v_out_b := blend8(unsigned(v_pix_tl( 7 downto  0)),
                                              unsigned(v_pix_tr( 7 downto  0)),
                                              unsigned(v_pix_bl( 7 downto  0)),
                                              unsigned(v_pix_br( 7 downto  0)),
                                              v_fx_q10, v_fy_q10);
                            dout_int <= std_logic_vector(v_out_r)
                                      & std_logic_vector(v_out_g)
                                      & std_logic_vector(v_out_b);
                        end if;

                        ce_pix_out_int <= '1';
                        de_out_int     <= '1';

                        if cnt_x_o = 0 then hs_out_gen <= '1';
                                       else hs_out_gen <= '0'; end if;
                        if cnt_y_o = 0 then vs_out_gen <= '1';
                                       else vs_out_gen <= '0'; end if;

                        if cnt_x_o = DST_W - 1 then
                            cnt_x_o <= 0;
                            src_x_q15 <= 0;
                            if cnt_y_o = DST_H - 1 then
                                cnt_y_o <= 0;
                                src_y_q15 <= 0;
                            else
                                cnt_y_o <= cnt_y_o + 1;
                                src_y_q15 <= src_y_q15 + SRC_Y_STEP_Q15;
                            end if;
                        else
                            cnt_x_o <= cnt_x_o + 1;
                            src_x_q15 <= src_x_q15 + SRC_X_STEP_Q15;
                        end if;
                    end if;
                end if;

                -- Drive read_need_y / read_need_y1 for cache-fill FSM.
                -- Use the JUST-COMPUTED src_y (warp or linear).
                if read_active = '1' then
                    if warp_en = '0' then
                        v_src_y_q15_now := src_y_q15;
                    else
                        v_dx := cnt_x_o - DST_CX;
                        v_dy := cnt_y_o - DST_CY;
                        if v_dx < 0 then v_dx_abs := -v_dx; else v_dx_abs := v_dx; end if;
                        if v_dy < 0 then v_dy_abs := -v_dy; else v_dy_abs := v_dy; end if;
                        v_dx2 := v_dx_abs * v_dx_abs;
                        v_dy2 := v_dy_abs * v_dy_abs;
                        v_r2  := AX2_DST_Q24 * v_dx2 + AY2_DST_Q24 * v_dy2;
                        v_m   := to_integer(warp_m_lookup(to_unsigned(v_r2, 32)));
                        v_dst_dy_w_q15 := v_dy * v_m;
                        v_src_y_q15_now := SRC_CY_Q15
                                          + (v_dst_dy_w_q15 * SRC_H) / DST_H;
                    end if;
                    v_src_yi := v_src_y_q15_now / (2**15);
                    if v_src_yi >= 0 and v_src_yi < SRC_H then
                        read_need_y  <= v_src_yi;
                        if v_src_yi + 1 < SRC_H then
                            read_need_y1 <= v_src_yi + 1;
                        else
                            read_need_y1 <= v_src_yi;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- ---- Sync forwarding ----
    process(clk)
    begin
        if rising_edge(clk) then
            if ce_pix_in = '1' then
                hs_in_d  <= hs_in;
                vs_in_d2 <= vs_in;
            end if;
        end if;
    end process;

    -- ============================================================
    -- STAGE 4a: Bloom pipeline
    -- ============================================================
    -- One process drives the 3-tap horizontal shift register, the line
    -- buffer writes, the cnt_x_b / cnt_y_b counters, and the sync shift
    -- register. The v_blur + mix combinational stage produces
    -- bloomed_pix from the line buffers and the current h_blur (i.e. on
    -- the SAME emit event that h_blur is generated, the prev1 and prev2
    -- line-buffer reads at cnt_x_b are aligned).
    bloom_pipe : process(clk)
        variable v_pix0_r, v_pix0_g, v_pix0_b : unsigned(7 downto 0);
        variable v_pix1_r, v_pix1_g, v_pix1_b : unsigned(7 downto 0);
        variable v_pix2_r, v_pix2_g, v_pix2_b : unsigned(7 downto 0);
        variable v_h_r, v_h_g, v_h_b : unsigned(9 downto 0);
        variable v_h_byte_r, v_h_byte_g, v_h_byte_b : unsigned(7 downto 0);
        variable v_lb1_r, v_lb1_g, v_lb1_b : unsigned(7 downto 0);
        variable v_lb2_r, v_lb2_g, v_lb2_b : unsigned(7 downto 0);
        variable v_v_r, v_v_g, v_v_b : unsigned(9 downto 0);
        variable v_blur_r, v_blur_g, v_blur_b : unsigned(7 downto 0);
        variable v_orig_r, v_orig_g, v_orig_b : unsigned(7 downto 0);
        variable v_inv_mix : unsigned(8 downto 0);
        variable v_mix_r, v_mix_g, v_mix_b : unsigned(15 downto 0);
        variable v_lerp_r, v_lerp_g, v_lerp_b : unsigned(7 downto 0);
        variable v_halo_r_full, v_halo_g_full, v_halo_b_full : unsigned(15 downto 0);
        variable v_halo_r, v_halo_g, v_halo_b : unsigned(7 downto 0);
        variable v_max_r, v_max_g, v_max_b : unsigned(7 downto 0);
        variable v_out_r, v_out_g, v_out_b : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            if reset = '1' then
                bl_pix0 <= (others => '0');
                bl_pix1 <= (others => '0');
                bl_pix2 <= (others => '0');
                h_blur_now <= (others => '0');
                cnt_x_b <= 0;
                cnt_y_b <= 0;
                ce_sh <= (others => '0');
                de_sh <= (others => '0');
                hs_sh <= (others => '0');
                vs_sh <= (others => '0');
                for i in 0 to 2 loop
                    orig_sh(i) <= (others => '0');
                end loop;
                bloomed_pix <= (others => '0');
            else
                -- ALWAYS shift the sync shift register every cycle.
                -- Insert '1' at stage 0 only when a fresh emit happens
                -- this cycle (ce_pix_out_int='1'), else insert '0'.
                -- This makes ce_sh(2) a one-cycle pulse per emit
                -- (offset by 2 cycles from the underlying emit), which
                -- is what downstream consumers (final ce_pix_out) and
                -- testbench captures expect.
                ce_sh <= ce_sh(1 downto 0) & ce_pix_out_int;
                de_sh <= de_sh(1 downto 0) & (de_out_int and ce_pix_out_int);
                -- Sample hs/vs gen only on emit (else hold prior).
                if ce_pix_out_int = '1' then
                    hs_sh <= hs_sh(1 downto 0) & hs_out_gen;
                    vs_sh <= vs_sh(1 downto 0) & vs_out_gen;
                    orig_sh(2) <= orig_sh(1);
                    orig_sh(1) <= orig_sh(0);
                    orig_sh(0) <= dout_int;
                    y_sh(2) <= y_sh(1);
                    y_sh(1) <= y_sh(0);
                    y_sh(0) <= cnt_y_o;
                end if;

                if ce_pix_out_int = '1' then
                    -- ---- 1. Shift horizontal-blur 3-tap register ----
                    bl_pix2 <= bl_pix1;
                    bl_pix1 <= bl_pix0;
                    bl_pix0 <= dout_int;

                    -- ---- 2. Compute h_blur centered on the OLD bl_pix1
                    -- (which is the value present *before* the shift above
                    -- takes effect). With separate ladder of pixels:
                    --   bl_pix2 = oldest (left neighbour of center)
                    --   bl_pix1 = center
                    --   bl_pix0 = newest (right neighbour of center)
                    -- Coefficients (1, 2, 1) >> 2.
                    v_pix2_r := unsigned(bl_pix2(23 downto 16));
                    v_pix2_g := unsigned(bl_pix2(15 downto 8));
                    v_pix2_b := unsigned(bl_pix2(7 downto 0));
                    v_pix1_r := unsigned(bl_pix1(23 downto 16));
                    v_pix1_g := unsigned(bl_pix1(15 downto 8));
                    v_pix1_b := unsigned(bl_pix1(7 downto 0));
                    v_pix0_r := unsigned(bl_pix0(23 downto 16));
                    v_pix0_g := unsigned(bl_pix0(15 downto 8));
                    v_pix0_b := unsigned(bl_pix0(7 downto 0));
                    v_h_r := resize(v_pix2_r + v_pix1_r + v_pix1_r + v_pix0_r, 10);
                    v_h_g := resize(v_pix2_g + v_pix1_g + v_pix1_g + v_pix0_g, 10);
                    v_h_b := resize(v_pix2_b + v_pix1_b + v_pix1_b + v_pix0_b, 10);
                    v_h_byte_r := resize(shift_right(v_h_r, 2), 8);
                    v_h_byte_g := resize(shift_right(v_h_g, 2), 8);
                    v_h_byte_b := resize(shift_right(v_h_b, 2), 8);
                    h_blur_now <= std_logic_vector(v_h_byte_r)
                                & std_logic_vector(v_h_byte_g)
                                & std_logic_vector(v_h_byte_b);

                    -- ---- 3. Sample line buffers at cnt_x_b
                    -- (prev 2 output rows' h_blur).
                    v_lb1_r := unsigned(lb_prev1(cnt_x_b)(23 downto 16));
                    v_lb1_g := unsigned(lb_prev1(cnt_x_b)(15 downto 8));
                    v_lb1_b := unsigned(lb_prev1(cnt_x_b)(7 downto 0));
                    v_lb2_r := unsigned(lb_prev2(cnt_x_b)(23 downto 16));
                    v_lb2_g := unsigned(lb_prev2(cnt_x_b)(15 downto 8));
                    v_lb2_b := unsigned(lb_prev2(cnt_x_b)(7 downto 0));

                    -- ---- 4. Write h_blur into lb_prev1, cascade lb_prev1
                    -- into lb_prev2 at the SAME column. ----
                    lb_prev2(cnt_x_b) <= lb_prev1(cnt_x_b);
                    lb_prev1(cnt_x_b) <= std_logic_vector(v_h_byte_r)
                                       & std_logic_vector(v_h_byte_g)
                                       & std_logic_vector(v_h_byte_b);

                    -- ---- 5. v_blur = (lb2 + 2*lb1 + h_byte) >> 2 ----
                    v_v_r := resize(v_lb2_r + v_lb1_r + v_lb1_r + v_h_byte_r, 10);
                    v_v_g := resize(v_lb2_g + v_lb1_g + v_lb1_g + v_h_byte_g, 10);
                    v_v_b := resize(v_lb2_b + v_lb1_b + v_lb1_b + v_h_byte_b, 10);
                    v_blur_r := resize(shift_right(v_v_r, 2), 8);
                    v_blur_g := resize(shift_right(v_v_g, 2), 8);
                    v_blur_b := resize(shift_right(v_v_b, 2), 8);

                    -- ---- 6. Mix per bloom_mode/en ----
                    -- The "orig" pixel for mixing is the one at the
                    -- center of the kernel = bl_pix1 (= old bl_pix0
                    -- before shift, == 2 emits ago in the stream).
                    v_orig_r := v_pix1_r;
                    v_orig_g := v_pix1_g;
                    v_orig_b := v_pix1_b;

                    if bloom_en = '0' then
                        v_out_r := v_orig_r;
                        v_out_g := v_orig_g;
                        v_out_b := v_orig_b;
                    elsif bloom_mode = "01" then
                        -- LERP: out = (orig*(256-mix) + blur*mix + 128) >> 8
                        v_inv_mix := to_unsigned(256, 9) - resize(bloom_mix_q8, 9);
                        v_mix_r := resize(v_orig_r * v_inv_mix(7 downto 0)
                                          + v_blur_r * bloom_mix_q8
                                          + to_unsigned(128, 16), 16);
                        v_mix_g := resize(v_orig_g * v_inv_mix(7 downto 0)
                                          + v_blur_g * bloom_mix_q8
                                          + to_unsigned(128, 16), 16);
                        v_mix_b := resize(v_orig_b * v_inv_mix(7 downto 0)
                                          + v_blur_b * bloom_mix_q8
                                          + to_unsigned(128, 16), 16);
                        v_lerp_r := resize(shift_right(v_mix_r, 8), 8);
                        v_lerp_g := resize(shift_right(v_mix_g, 8), 8);
                        v_lerp_b := resize(shift_right(v_mix_b, 8), 8);
                        v_out_r := v_lerp_r;
                        v_out_g := v_lerp_g;
                        v_out_b := v_lerp_b;
                    elsif bloom_mode = "10" then
                        -- MAX-BLEND: halo = sat((blur * gain + 8) >> 4)
                        --            out  = max(orig, halo)
                        v_halo_r_full := resize(v_blur_r * bloom_gain
                                                + to_unsigned(8, 5), 16);
                        v_halo_g_full := resize(v_blur_g * bloom_gain
                                                + to_unsigned(8, 5), 16);
                        v_halo_b_full := resize(v_blur_b * bloom_gain
                                                + to_unsigned(8, 5), 16);
                        if shift_right(v_halo_r_full, 4) > to_unsigned(255, 16) then
                            v_halo_r := to_unsigned(255, 8);
                        else
                            v_halo_r := resize(shift_right(v_halo_r_full, 4), 8);
                        end if;
                        if shift_right(v_halo_g_full, 4) > to_unsigned(255, 16) then
                            v_halo_g := to_unsigned(255, 8);
                        else
                            v_halo_g := resize(shift_right(v_halo_g_full, 4), 8);
                        end if;
                        if shift_right(v_halo_b_full, 4) > to_unsigned(255, 16) then
                            v_halo_b := to_unsigned(255, 8);
                        else
                            v_halo_b := resize(shift_right(v_halo_b_full, 4), 8);
                        end if;
                        if v_orig_r >= v_halo_r then v_max_r := v_orig_r;
                                                else v_max_r := v_halo_r; end if;
                        if v_orig_g >= v_halo_g then v_max_g := v_orig_g;
                                                else v_max_g := v_halo_g; end if;
                        if v_orig_b >= v_halo_b then v_max_b := v_orig_b;
                                                else v_max_b := v_halo_b; end if;
                        v_out_r := v_max_r;
                        v_out_g := v_max_g;
                        v_out_b := v_max_b;
                    else
                        -- mode 00 (Off) or 11 (reserved): passthrough.
                        v_out_r := v_orig_r;
                        v_out_g := v_orig_g;
                        v_out_b := v_orig_b;
                    end if;

                    bloomed_pix <= std_logic_vector(v_out_r)
                                 & std_logic_vector(v_out_g)
                                 & std_logic_vector(v_out_b);

                    -- ---- 7. Counters: cnt_x_b/cnt_y_b track the emit
                    -- center (= bl_pix1 = 1 emit behind cnt_x_o/y_o).
                    if cnt_x_b = DST_W - 1 then
                        cnt_x_b <= 0;
                        if cnt_y_b = DST_H - 1 then cnt_y_b <= 0;
                        else cnt_y_b <= cnt_y_b + 1; end if;
                    else
                        cnt_x_b <= cnt_x_b + 1;
                    end if;

                    -- (sync shift register is already updated outside
                    -- the emit-gated block above; nothing to do here.)
                    null;
                end if;
            end if;
        end if;
    end process;

    -- ============================================================
    -- STAGE 4b: Scanlines (per OUTPUT row, post-bloom)
    -- ============================================================
    -- Combinational modulation of bloomed_pix by a Q0.8 brightness
    -- factor read from the 32-entry SCANLINE_LUT (defined in
    -- vis_warp_luts_pkg, triangular shape with gap=64/255 = 25%).
    --
    -- Phase indexing uses y_sh(2) — the cnt_y_o value at the time the
    -- bloomed_pix being modulated was the kernel center (i.e. delayed
    -- by 2 emits to match the bloom output). For DST coordinates this
    -- gives precise per-output-row scanlines (not chunky per-source-row
    -- like the Phase 1 write-side approach).
    --
    -- Density mapping (scanlines port):
    --   00 (Off)    -> sl_q8 = 255 -> no modulation.
    --   01 (Light)  -> period 8 rows (log2 = 3).
    --   10 (Medium) -> period 4 rows (log2 = 2).
    --   11 (Heavy)  -> period 2 rows (log2 = 1) -- classic CRT alternation.
    scanline_mod : process(bloomed_pix, y_sh, scanlines)
        variable v_period_log2 : integer;
        variable v_y : integer;
        variable v_phase_q : unsigned(30 downto 0);
        variable v_sl_idx : integer range 0 to 31;
        variable v_sl_q8 : unsigned(7 downto 0);
        variable v_r, v_g, v_b : unsigned(7 downto 0);
        variable v_r_mod, v_g_mod, v_b_mod : unsigned(15 downto 0);
    begin
        -- When scanlines='00' (Off), bypass the multiply entirely so the
        -- output is bit-exact equal to bloomed_pix. (Using sl_q8=255
        -- here would introduce a 255/256 rounding error per channel.)
        if scanlines = "00" then
            final_pix <= bloomed_pix;
        else
            case scanlines is
                when "01" => v_period_log2 := 3;
                when "10" => v_period_log2 := 2;
                when "11" => v_period_log2 := 1;
                when others => v_period_log2 := 1;
            end case;
            v_y := y_sh(2);
            -- phase = (y << 15) & ((1<<(15+log2))-1)  (mod period in Q15)
            v_phase_q := shift_left(to_unsigned(v_y, 31), 15) and
                         to_unsigned((2**(15 + v_period_log2)) - 1, 31);
            v_sl_idx := to_integer(shift_right(v_phase_q,
                                               v_period_log2 + 10)) mod 32;
            v_sl_q8 := SCANLINE_LUT(v_sl_idx);

            v_r := unsigned(bloomed_pix(23 downto 16));
            v_g := unsigned(bloomed_pix(15 downto 8));
            v_b := unsigned(bloomed_pix(7 downto 0));
            v_r_mod := resize(v_r * v_sl_q8 + to_unsigned(128, 16), 16);
            v_g_mod := resize(v_g * v_sl_q8 + to_unsigned(128, 16), 16);
            v_b_mod := resize(v_b * v_sl_q8 + to_unsigned(128, 16), 16);
            final_pix <= std_logic_vector(v_r_mod(15 downto 8))
                       & std_logic_vector(v_g_mod(15 downto 8))
                       & std_logic_vector(v_b_mod(15 downto 8));
        end if;
    end process;

    -- ============================================================
    -- DDR3 (Avalon-MM) wiring
    --
    -- Bus arbiter: writes take priority. If a write is pending, suppress
    -- the read pulse (the cache FSM's cf_chunks_issued already incremented
    -- — but the read never actually issued. We must NOT issue the read
    -- under any circumstance when wr_pending='1', because the address mux
    -- routes wr_pending_addr in that case, and a stray avl_read pulse
    -- would land at the write address, polluting the read pipeline with
    -- bogus data and corrupting the line cache.)
    --
    -- See Phase 2 stage-3c debug notes: the prior bug was that avl_read
    -- could pulse while avl_address was the write address, causing the
    -- mock to return the WRITE row's data into the cache slot intended
    -- for a row read.
    -- ============================================================
    avl_address <= std_logic_vector(to_unsigned(wr_pending_addr * 16, AW))
                       when wr_pending = '1'
                       else std_logic_vector(to_unsigned(cf_issue_addr * 16, AW));
    avl_burstcount <= std_logic_vector(to_unsigned(1, BCW));
    avl_writedata  <= wr_pending_data;
    avl_byteenable <= (others => '1');
    avl_write      <= wr_pending and (not avl_waitrequest);
    avl_read       <= cf_issue_pulse and (not avl_waitrequest)
                                     and (not wr_pending);

    -- ============================================================
    -- Output assignment
    -- ============================================================
    -- The full FX chain is: warp/bilinear -> bloom -> scanlines.
    --
    -- When ALL FX are off (bloom_en='0' AND scanlines="00"), BYPASS
    -- the post-warp pipeline entirely — output goes directly from the
    -- warp/bilinear stage with 0-emit latency. This preserves the
    -- stage-3c bit-exact regressions.
    --
    -- When ANY FX is on, route through the bloom+scanlines pipeline
    -- which adds 2 emit-events of latency:
    --   - emit 0: bl_pix0 latched (= dout_int from warp/bilinear).
    --   - emit 1: h_blur_now computed (centered on bl_pix1).
    --   - emit 2: v_blur computed, mix produces bloomed_pix;
    --             scanline_mod runs combinationally on bloomed_pix
    --             using y_sh(2) -> final_pix.
    --
    -- Sync signals (ce, de, hs, vs) live in ce_sh/de_sh/hs_sh/vs_sh,
    -- stage(2) = the final output. (When bloom_en='0' but scanlines
    -- on, the bloom pipeline still runs but its lerp/max-blend mix
    -- collapses to passthrough so bloomed_pix = orig — and final_pix
    -- = orig * scanline. The 2-emit latency still applies; this is
    -- the trade-off for constant-timing operation in the firmware's
    -- "scanlines but no bloom" config.)
    dout       <= final_pix     when (bloom_en = '1' or scanlines /= "00")
                                else dout_int;
    ce_pix_out <= ce_sh(2)      when (bloom_en = '1' or scanlines /= "00")
                                else ce_pix_out_int;
    de_out     <= de_sh(2)      when (bloom_en = '1' or scanlines /= "00")
                                else de_out_int;
    hs_out     <= hs_sh(2)      when (bloom_en = '1' or scanlines /= "00")
                                else hs_out_gen;
    vs_out     <= vs_sh(2)      when (bloom_en = '1' or scanlines /= "00")
                                else vs_out_gen;

    dbg_cnt_x_o <= cnt_x_o;
    dbg_cnt_y_o <= cnt_y_o;

end architecture;
