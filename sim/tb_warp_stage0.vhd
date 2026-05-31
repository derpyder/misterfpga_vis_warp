-- tb_warp_stage0 -- Stage-0 de-risk testbench for vis_warp_v2_wp
-- (SPEC-cylindrical-warp.md §5 Stage 0; the reclaim's validation rig.)
--
-- Drives the engine with a synthetic raster (small frame, 1px grid pattern),
-- captures the LAST complete output frame (latency-agnostic: works whether the
-- output is delayed 64 lines by the sync FIFO, as today, or ~17 cycles after the
-- reclaim), and dumps it to sim/warp_out/tb_stage0_frame.txt for golden-compare
-- in Python. The pattern is STATIC across frames, so the FIFO delay doesn't
-- matter -- any complete output frame reflects the input.
--
-- Checks (in the Python comparator, tb_stage0_check.py):
--   * kv=0  => src_y == out_y  : a horizontal grid line stays on its row.
--   * warp active              : vertical grid lines bow (column varies by row).
--
-- Run (from sim/):
--   GH=/c/Users/mattl/bin/ghdl/bin/ghdl.exe ; S=../sys
--   "$GH" -a --std=08 --workdir=ghdl_work \
--     "$S/vis_warp_pkg_v2.vhd" "$S/vis_warp_luts_pkg.vhd" "$S/vis_warp_rescal.vhd" \
--     "$S/vis_warp_v2_wp.vhd" tb_warp_stage0.vhd
--   "$GH" -e --std=08 --workdir=ghdl_work tb_warp_stage0
--   "$GH" -r --std=08 --workdir=ghdl_work tb_warp_stage0 --stop-time=20ms

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_warp_stage0 is
    generic (DUT_N_LINES : integer := 128;   -- 128 = spherical; 2 = cylindrical reclaim
             DUT_BIL     : integer := 1;     -- 1 = bilinear, 0 = nearest-neighbour
             CE_DIV      : integer := 1;     -- input ce_pix period in clks (>=2 = headroom
                                             --   for hi-res 2x output emit)
             OUT_SCALE   : integer := 1;     -- DUT output upscale (1 = src-res, 2 = hi-res 2x);
                                             --   pair OUT_SCALE=2 with CE_DIV>=2 for the headroom
             W_ACT_G     : integer := 64;    -- active source width  (296 = Robotron, for the
                                             --   doubling gate; 64 = fast structural sim)
             H_ACT_G     : integer := 48;    -- active source height
             GRID_G      : integer := 8;     -- 1px grid line every GRID_G px
             N_FRAMES_G  : integer := 6;     -- enough to clear the sync-FIFO fill
             SHARP_G     : integer := 4);    -- sharp-bilinear K (runtime `sharpness`).
                                             --   4 = dev-default (near-NN); at OUT_SCALE=2 the
                                             --   2x res already supplies crispness, so a SOFTER
                                             --   value (1-2) avoids re-snapping half-px boundaries.
end entity;

architecture sim of tb_warp_stage0 is

    -- ---- raster geometry (parameterized; htotal >= LINE_LEN_MIN=64) ----
    constant W_ACT   : integer := W_ACT_G;       -- 4:3-ish so the warp is symmetric
    constant W_BLK   : integer := 24;            -- htotal = W_ACT+24 (>= LINE_LEN_MIN=64)
    constant H_ACT   : integer := H_ACT_G;
    constant H_BLK   : integer := 8;
    constant W_TOTAL : integer := W_ACT + W_BLK;
    constant V_TOTAL : integer := H_ACT + H_BLK;
    constant HS_START: integer := W_ACT + 6;
    constant HS_END  : integer := W_ACT + 14;
    constant VS_START: integer := H_ACT + 2;
    constant VS_END  : integer := H_ACT + 4;
    constant GRID    : integer := GRID_G;        -- 1px grid line every GRID px
    constant N_FRAMES: integer := N_FRAMES_G;
    -- The emitted (captured) line is OUT_SCALE x wider: the hi-res raster.
    constant OUT_W   : integer := OUT_SCALE * W_ACT;

    signal clk      : std_logic := '0';
    signal reset    : std_logic := '1';
    signal done     : boolean   := false;

    signal warp_en     : std_logic := '1';
    signal curvature_k : unsigned(2 downto 0) := "010"; -- k=2
    signal curvature_v : unsigned(2 downto 0) := "000"; -- kv=0 -> cylinder, src_y=out_y
    signal bilinear_en : std_logic := '1';  -- driven from DUT_BIL below
    signal sharpness   : unsigned(2 downto 0) := to_unsigned(SHARP_G, 3); -- sharp-bilinear K
    signal ce_pix      : std_logic := '1';              -- 1 pixel per clk (CE_DIV=1)

    signal r_in, g_in, b_in : std_logic_vector(7 downto 0) := (others => '0');
    signal hs_in, vs_in, de_in : std_logic := '0';
    signal r_out, g_out, b_out : std_logic_vector(7 downto 0);
    signal hs_out, vs_out, de_out : std_logic;
    signal ce_pix_out  : std_logic;               -- DUT emit enable (OUT_SCALE x ce_pix_dly)

    -- ---- captured frames (OUT_W wide = the hi-res output raster) ----
    type row_t   is array (0 to OUT_W-1) of integer range 0 to 255;
    type frame_t is array (0 to H_ACT-1) of row_t;
    signal cur_frame  : frame_t := (others => (others => 0));
    signal last_frame : frame_t := (others => (others => 0));
    signal frames_seen : integer := 0;

begin

    bilinear_en <= '1' when DUT_BIL = 1 else '0';

    -- clock
    clk_proc : process
    begin
        while not done loop
            clk <= '0'; wait for 5 ns;
            clk <= '1'; wait for 5 ns;
        end loop;
        wait;
    end process;

    reset <= '1', '0' after 105 ns;

    -- DUT: the engine, default generics (MAX_SRC_W=512, N_LINES=128)
    dut : entity work.vis_warp_v2_wp
        generic map (N_LINES => DUT_N_LINES, CYL_MODE => (DUT_N_LINES = 2),
                     OUT_SCALE => OUT_SCALE)
        port map (
            clk         => clk,
            reset       => reset,
            warp_en     => warp_en,
            curvature_k => curvature_k,
            bilinear_en => bilinear_en,
            sharpness   => sharpness,
            curvature_v => curvature_v,
            ce_pix      => ce_pix,
            r_in => r_in, g_in => g_in, b_in => b_in,
            hs_in => hs_in, vs_in => vs_in, de_in => de_in,
            r_out => r_out, g_out => g_out, b_out => b_out,
            hs_out => hs_out, vs_out => vs_out, de_out => de_out,
            ce_pix_out => ce_pix_out
        );

    -- ---- input raster generator (ce_pix pulses every CE_DIV clks) ----
    -- Inputs are registered from (ix,iy) and ce_pix is registered together, so the
    -- whole stream is delayed 1 clk uniformly -> the engine sees pixel(ix) on the
    -- clk where ce_pix='1'. The raster advances one pixel per ce_pix. CE_DIV=1
    -- reproduces the old ce-every-clk behaviour; CE_DIV>=2 leaves clk headroom for
    -- a 2x-rate output emit (hi-res).
    input_gen : process(clk)
        variable ix : integer range 0 to W_TOTAL-1 := 0;
        variable iy : integer range 0 to V_TOTAL-1 := 0;
        variable fr : integer := 0;
        variable ph : integer range 0 to 31 := 0;
        variable lit : boolean;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ix := 0; iy := 0; fr := 0; ph := 0;
                ce_pix <= '0';
                hs_in <= '0'; vs_in <= '0'; de_in <= '0';
                r_in <= x"00"; g_in <= x"00"; b_in <= x"00";
            else
                -- sync + pattern for current (ix,iy), held across the non-ce clks
                if ix >= HS_START and ix < HS_END then hs_in <= '1'; else hs_in <= '0'; end if;
                if iy >= VS_START and iy < VS_END then vs_in <= '1'; else vs_in <= '0'; end if;
                if ix < W_ACT and iy < H_ACT then
                    de_in <= '1';
                    lit := (ix mod GRID = 0) or (iy mod GRID = 0);
                    if lit then
                        r_in <= x"FF"; g_in <= x"FF"; b_in <= x"FF";
                    else
                        r_in <= x"00"; g_in <= x"00"; b_in <= x"00";
                    end if;
                else
                    de_in <= '0';
                    r_in <= x"00"; g_in <= x"00"; b_in <= x"00";
                end if;
                -- ce_pix every CE_DIV clks; advance the raster on the ce clk
                if ph = CE_DIV - 1 then
                    ce_pix <= '1';
                    ph := 0;
                    if ix = W_TOTAL-1 then
                        ix := 0;
                        if iy = V_TOTAL-1 then
                            iy := 0; fr := fr + 1;
                            if fr >= N_FRAMES then done <= true; end if;
                        else
                            iy := iy + 1;
                        end if;
                    else
                        ix := ix + 1;
                    end if;
                else
                    ce_pix <= '0';
                    ph := ph + 1;
                end if;
            end if;
        end if;
    end process;

    -- ---- output capture: build cur_frame, snapshot to last_frame each vs rising ----
    -- Pixel writes are gated on ce_pix_out (the DUT emit enable): at OUT_SCALE=2 the
    -- output runs at 2x rate, so one r_out per ce_pix_out pulse fills OUT_W columns
    -- across a line. The de/vs EDGE detects stay un-gated (level changes land on any
    -- clk). At OUT_SCALE=1/CE_DIV=1, ce_pix_out pulses every clk => identical capture.
    out_cap : process(clk)
        variable ox   : integer range 0 to OUT_SCALE * W_TOTAL := 0;
        variable oy   : integer range 0 to V_TOTAL := 0;
        variable de_d : std_logic := '0';
        variable vs_d : std_logic := '0';
    begin
        if rising_edge(clk) then
            if reset = '1' then
                ox := 0; oy := 0; de_d := '0'; vs_d := '0';
            else
                if vs_out = '1' and vs_d = '0' then
                    -- frame boundary: the frame we just filled is complete
                    last_frame  <= cur_frame;
                    frames_seen <= frames_seen + 1;
                    cur_frame   <= (others => (others => 0));
                    ox := 0; oy := 0;
                elsif de_out = '0' and de_d = '1' then
                    -- end of an active line
                    if oy < V_TOTAL then oy := oy + 1; end if;
                    ox := 0;
                elsif de_out = '1' and ce_pix_out = '1' then
                    if oy < H_ACT and ox < OUT_W then
                        cur_frame(oy)(ox) <= to_integer(unsigned(r_out));
                    end if;
                    -- Saturate (don't overflow ox's range) during the startup
                    -- transient where target_lag is still settling and de_out can
                    -- stretch past one line. Real lines are <= OUT_W < the cap.
                    if ox < OUT_SCALE * W_TOTAL then ox := ox + 1; end if;
                end if;
                de_d := de_out;
                vs_d := vs_out;
            end if;
        end if;
    end process;

    -- ---- dump the last complete frame + a quick stat summary ----
    dump_proc : process
        file     f      : text;
        variable l      : line;
        variable st     : file_open_status;
        variable nbright: integer := 0;
    begin
        wait until done;
        wait for 1 ns;
        file_open(st, f, "warp_out/tb_stage0_frame.txt", write_mode);
        for yy in 0 to H_ACT-1 loop
            for xx in 0 to OUT_W-1 loop
                write(l, last_frame(yy)(xx));
                write(l, ' ');
                if last_frame(yy)(xx) > 96 then nbright := nbright + 1; end if;
            end loop;
            writeline(f, l);
        end loop;
        file_close(f);
        report "TB stage0: frames_seen=" & integer'image(frames_seen)
             & "  out_dims=" & integer'image(OUT_W) & "x" & integer'image(H_ACT)
             & "  bright_px=" & integer'image(nbright)
             & "  (file: warp_out/tb_stage0_frame.txt)" severity note;
        wait;
    end process;

end architecture;
