-- vis_warp_v2 -- framework-side STAND-IN for Agent A's Phase 2 RTL.
--
-- This is NOT the real implementation. It is a passthrough stand-in with
-- the exact port shape of the real vis_warp_v2 in
-- D:\deck\fpga\pacman-vis\sim\rtl\vis_warp_v2.vhd (as of commit cb7c2a1
-- on branch wip-stage3c-rescue). The stand-in lets the framework wrapper
-- (sys/vis_warp.vhd) compile and exercise its control-register wiring
-- before Agent A's stage 4 commit lands.
--
-- WHEN AGENT A'S STAGE 4 LANDS (milestone B3):
--   1. Copy D:/deck/fpga/pacman-vis/sim/rtl/vis_warp_v2.vhd over this file
--   2. Copy vis_warp_pkg_v2.vhd + vis_warp_luts_pkg.vhd into sys/
--   3. Add both packages to sys/sys.qip ABOVE this entity
--   4. (Likely) add the 5 missing control input ports listed in
--      "GAP LIST" below to A's entity, and wire them in sys/vis_warp.vhd.
--
-- Behavior of THIS stand-in:
--   - din -> dout 1-cycle latch (gated by ce_pix_in)
--   - hs/vs/de forwarded
--   - ce_pix_out = ce_pix_in delayed 1 cycle
--   - avl_* tied off (no DDR3 traffic)
--   - dbg_cnt_* drive 0
--
-- GAP LIST (what THIS entity exposes vs what the wrapper drives):
--   Wrapper drives:  warp_en, bilinear_en, bloom_en, bloom_mode,
--                    bloom_gain, scanlines_dens, curvature_k
--   v2 (today)     : warp_en ONLY
--   Real v2 stg4   : needs to add the other 6 as input ports. Until then
--                    the wrapper holds them in registers and they're left
--                    unconnected at the v2 boundary -- harmless.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vis_warp_v2 is
    generic (
        SRC_W       : integer := 288;
        SRC_H       : integer := 224;
        DST_W       : integer := 288;
        DST_H       : integer := 224;
        ARX         : integer := 2880;
        ARY         : integer := 2219;
        AW          : integer := 28;
        DW          : integer := 128;
        BEW         : integer := 16;
        BCW         : integer := 8;
        BANK_A_BASE : integer := 16#2080000#;  -- 0x20800000 / 16 (word addr)
        BANK_B_BASE : integer := 16#2100000#   -- 0x21000000 / 16
    );
    port (
        clk         : in  std_logic;
        reset       : in  std_logic;

        warp_en     : in  std_logic;

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
        avl_waitrequest   : in  std_logic;

        dbg_cnt_x_o : out integer;
        dbg_cnt_y_o : out integer
    );
end entity;

architecture standin of vis_warp_v2 is
    -- Lint keepers
    signal warp_en_keep   : std_logic;
    signal avl_rd_keep    : std_logic_vector(DW - 1 downto 0);
    signal avl_rdv_keep   : std_logic;
    signal avl_wr_keep    : std_logic;
begin

    warp_en_keep <= warp_en;
    avl_rd_keep  <= avl_readdata;
    avl_rdv_keep <= avl_readdatavalid;
    avl_wr_keep  <= avl_waitrequest;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                dout       <= (others => '0');
                hs_out     <= '0';
                vs_out     <= '0';
                de_out     <= '0';
                ce_pix_out <= '0';
            else
                ce_pix_out <= ce_pix_in;
                if ce_pix_in = '1' then
                    dout   <= din;
                    hs_out <= hs_in;
                    vs_out <= vs_in;
                    de_out <= de_in;
                end if;
            end if;
        end if;
    end process;

    avl_address    <= (others => '0');
    avl_burstcount <= (others => '0');
    avl_writedata  <= (others => '0');
    avl_byteenable <= (others => '0');
    avl_write      <= '0';
    avl_read       <= '0';

    dbg_cnt_x_o <= 0;
    dbg_cnt_y_o <= 0;

end architecture;
