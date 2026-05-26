-- vis_warp -- MiSTer framework video FX module (Phase 2 framework integration)
--
-- INSERTION POINT: between sys_top.v's `vga_data_sl` (post-scanlines) and
-- ascal's `i_r/i_g/i_b` inputs. See sys_top.v:1712-1719 for the splice.
--
-- This is the STUB version: passthrough only, no DDR3 access, no FX. It
-- establishes the framework port contract so HPS firmware (Main_MiSTer-VIS)
-- + sys_top.v can be wired now. When the real Phase 2 RTL (vis_warp_v2
-- in pacman-vis/sim/rtl/) reaches stage 4, this stub gets replaced 1:1
-- with the full implementation.
--
-- FRAMEWORK PORT CONTRACT (locked):
--   - clk_sys      : config clock (cmd_wr / cmd_in are on this)
--   - clk_in       : source pixel clock (= clk_vid in sys_top)
--   - clk_out      : sink pixel clock   (= clk_hdmi in sys_top, scaler input)
--   - cmd_wr/cmd_in: HPS_BUS write port for runtime config (UIO 0x45)
--   - din/dout     : 24bpp RGB888
--   - hs/vs/de     : sync forwarding (input + output, may have CDC delay)
--   - display_w/h  : output frame size (so vis_warp knows the display rate)
--   - fb_en        : MISTER_FB bypass (ascal reads DDR3 directly; vis_warp
--                    must be invisible)
--   - vbuf         : Avalon-MM port to DDR3 vbuf channel (shared with ascal
--                    via vbuf_svc arbiter when fully integrated)
--
-- Stub behavior:
--   - dout = din (1-cycle latch for timing)
--   - syncs forwarded with the same latch
--   - cmd_wr / cmd_in ignored
--   - vbuf outputs tied to zero (no DDR3 traffic)
--
-- When fb_en=1 (MISTER_FB cores): same as stub (passthrough). Real module
-- will also bypass in this mode.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vis_warp is
    generic (
        AW  : integer := 28;
        DW  : integer := 128;
        BEW : integer := 16;
        BCW : integer := 8
    );
    port (
        clk_sys     : in  std_logic;
        clk_in      : in  std_logic;
        clk_out     : in  std_logic;

        -- HPS_BUS config (UIO 0x45)
        cmd_wr      : in  std_logic;
        cmd_in      : in  std_logic_vector(15 downto 0);

        -- Source side (post-scanlines, pre-ascal)
        ce_pix_in   : in  std_logic;
        din         : in  std_logic_vector(23 downto 0);
        hs_in       : in  std_logic;
        vs_in       : in  std_logic;
        de_in       : in  std_logic;

        -- Sink side (feeds ascal i_r/i_g/i_b)
        ce_pix_out  : out std_logic;
        dout        : out std_logic_vector(23 downto 0);
        hs_out      : out std_logic;
        vs_out      : out std_logic;
        de_out      : out std_logic;

        -- Display dims (for display-res FX in the real module)
        display_w   : in  std_logic_vector(11 downto 0);
        display_h   : in  std_logic_vector(11 downto 0);

        -- MISTER_FB bypass
        fb_en       : in  std_logic;

        -- DDR3 (vbuf channel; shared via vbuf_svc arbiter when real module
        -- replaces stub). Stub ties these to zero.
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
end entity;

architecture stub of vis_warp is
    -- Suppress "unused" warnings on inputs we don't touch in the stub
    signal cmd_in_keep    : std_logic_vector(15 downto 0);
    signal display_w_keep : std_logic_vector(11 downto 0);
    signal display_h_keep : std_logic_vector(11 downto 0);
    signal fb_en_keep     : std_logic;
    signal avl_rd_keep    : std_logic_vector(DW - 1 downto 0);
    signal avl_rdv_keep   : std_logic;
    signal avl_wr_keep    : std_logic;
begin

    cmd_in_keep    <= cmd_in;
    display_w_keep <= display_w;
    display_h_keep <= display_h;
    fb_en_keep     <= fb_en;
    avl_rd_keep    <= avl_readdata;
    avl_rdv_keep   <= avl_readdatavalid;
    avl_wr_keep    <= avl_waitrequest;

    -- ---- Passthrough on clk_in (gated by ce_pix_in) ----
    process(clk_in)
    begin
        if rising_edge(clk_in) then
            if ce_pix_in = '1' then
                dout   <= din;
                hs_out <= hs_in;
                vs_out <= vs_in;
                de_out <= de_in;
            end if;
        end if;
    end process;

    -- ce_pix_out follows ce_pix_in 1:1 in stub mode. Real module may
    -- emit at a different rate (display-res output).
    process(clk_in)
    begin
        if rising_edge(clk_in) then
            ce_pix_out <= ce_pix_in;
        end if;
    end process;

    -- HPS config writes ignored in stub
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            -- cmd_wr / cmd_in just consumed, no state update yet
            null;
        end if;
    end process;

    -- DDR3 outputs tied off (no traffic in stub)
    avl_address    <= (others => '0');
    avl_burstcount <= (others => '0');
    avl_writedata  <= (others => '0');
    avl_byteenable <= (others => '0');
    avl_write      <= '0';
    avl_read       <= '0';

end architecture;
