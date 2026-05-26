-- vis_warp -- MiSTer framework video FX module (Phase 2 framework wrapper)
--
-- This file is the framework-facing wrapper. It bridges the LOCKED port
-- contract that sys_top.v drives into the variable-shape implementation
-- entity vis_warp_v2 (which Agent A is iterating on under
-- D:\deck\fpga\pacman-vis\sim\rtl\). The contract has not changed since
-- the original stub:
--
--   - clk_sys      : config clock (cmd_wr / cmd_in run on this)
--   - clk_in       : source pixel clock (= clk_vid in sys_top)
--   - clk_out      : sink pixel clock   (= clk_hdmi in sys_top, scaler input)
--   - cmd_wr/cmd_in: HPS_BUS write port for runtime config (UIO 0x45),
--                    SIXTEEN BITS WIDE — matches Agent C's firmware
--                    (Main_MiSTer-VIS commit be6cb79).
--   - din/dout     : 24bpp RGB888
--   - hs/vs/de     : sync forwarding (input + output, may have CDC delay)
--   - display_w/h  : output frame size
--   - fb_en        : MISTER_FB bypass (this wrapper handles bypass itself,
--                    not vis_warp_v2)
--   - vbuf         : Avalon-MM port to DDR3 vbuf channel (shared with
--                    ascal via vbuf_svc arbiter)
--
-- This commit (B2.5 part 1 of 4) adds only the command decoder + control
-- registers. The video path is still pure passthrough and the DDR3 port
-- is tied off, so behavior is identical to the original stub.
--
-- Opcode encoding (cmd_in[15:13] = opcode, cmd_in[12:0] = payload). Must
-- match Main_MiSTer-VIS/video.cpp setVisWarp() EXACTLY:
--
--   000  flags     [0]=warp_en, [1]=bilinear_en, [2]=bloom_en, [3]=scanlines_en
--   001  curvature [2:0] = K strength
--   010  bloom     [12:11]=mode, [10:7]=gain (Q0.4 in max-blend mode)
--   011  scanlines [12:11]=density (0=Off,1=Light,2=Med,3=Heavy)
--   100  source_dims (reserved)
--   101  warp_lut    (reserved)
--   110  reserved
--   111  reset_internal
--
-- CDC NOTE: vis_warp_v2 (sim) is single-clock. On real HW the engine will
-- run on clk_sys while video crosses clk_in -> clk_out. Phase 2.5
-- milestone B4 will add dcfifo CDCs between domains; for now we drive v2's
-- single clk from clk_sys and document that B4 is the gating piece. The
-- control registers latch on clk_sys (same domain as cmd_wr) so they are
-- already in the right domain to feed v2's static control inputs.

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

        -- HPS_BUS config (UIO 0x45). Note: 16 bits, NOT 32 -- matches
        -- Agent C's spi_w() writes in setVisWarp().
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

        -- Display dims
        display_w   : in  std_logic_vector(11 downto 0);
        display_h   : in  std_logic_vector(11 downto 0);

        -- MISTER_FB bypass
        fb_en       : in  std_logic;

        -- DDR3 (vbuf channel via vbuf_svc ch1)
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

architecture wrapper of vis_warp is

    -- ---- Opcode encoding (matches Main_MiSTer-VIS/video.cpp setVisWarp) ----
    constant OP_FLAGS     : std_logic_vector(2 downto 0) := "000";
    constant OP_CURVATURE : std_logic_vector(2 downto 0) := "001";
    constant OP_BLOOM     : std_logic_vector(2 downto 0) := "010";
    constant OP_SCANLINES : std_logic_vector(2 downto 0) := "011";
    -- 100 / 101 reserved (source_dims / warp_lut), 110 reserved,
    -- 111 reset_internal.

    -- ---- Control registers (clk_sys domain) ----
    -- Defaults: everything OFF so a freshly-flashed core with no INI matches
    -- the existing stub's behavior.
    signal reg_enable     : std_logic := '0';                       -- flags[0] warp_en
    signal reg_bilinear   : std_logic := '0';                       -- flags[1]
    signal reg_bloom_en   : std_logic := '0';                       -- flags[2]
    signal reg_scan_en    : std_logic := '0';                       -- flags[3]
    signal reg_curvature  : std_logic_vector(2 downto 0) := "000";  -- K strength
    signal reg_bloom_mode : std_logic_vector(1 downto 0) := "00";   -- 0=lerp,1=max
    signal reg_bloom_gain : std_logic_vector(3 downto 0) := "0000"; -- Q0.4
    signal reg_scan_dens  : std_logic_vector(1 downto 0) := "00";   -- 0..3
    signal reg_reset_int  : std_logic := '0';                       -- 1-cycle pulse

    -- ---- Tie-off keepers for unused-input lint suppression ----
    signal display_w_keep : std_logic_vector(11 downto 0);
    signal display_h_keep : std_logic_vector(11 downto 0);
    signal fb_en_keep     : std_logic;
    signal avl_rd_keep    : std_logic_vector(DW - 1 downto 0);
    signal avl_rdv_keep   : std_logic;
    signal avl_wr_keep    : std_logic;

begin

    -- ---- Command decoder (clk_sys) ----
    -- One 16-bit write per opcode. reset_internal is a 1-cycle pulse so
    -- consumers downstream can edge-detect.
    process(clk_sys)
        variable v_op      : std_logic_vector(2 downto 0);
        variable v_payload : std_logic_vector(12 downto 0);
    begin
        if rising_edge(clk_sys) then
            reg_reset_int <= '0';  -- default: pulse low
            if cmd_wr = '1' then
                v_op      := cmd_in(15 downto 13);
                v_payload := cmd_in(12 downto 0);
                case v_op is
                    when OP_FLAGS =>
                        reg_enable   <= v_payload(0);
                        reg_bilinear <= v_payload(1);
                        reg_bloom_en <= v_payload(2);
                        reg_scan_en  <= v_payload(3);
                    when OP_CURVATURE =>
                        reg_curvature <= v_payload(2 downto 0);
                    when OP_BLOOM =>
                        -- Matches video.cpp: mode << 11, gain << 7
                        reg_bloom_mode <= v_payload(12 downto 11);
                        reg_bloom_gain <= v_payload(10 downto 7);
                    when OP_SCANLINES =>
                        -- density << 11
                        reg_scan_dens <= v_payload(12 downto 11);
                    when "111" =>
                        reg_reset_int <= '1';
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- ---- Passthrough on clk_in (placeholder; will be replaced by v2
    --      instantiation in commit 2 of this milestone) ----
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

    process(clk_in)
    begin
        if rising_edge(clk_in) then
            ce_pix_out <= ce_pix_in;
        end if;
    end process;

    -- ---- Unused-input keepers (lint hygiene; will be wired into v2 next
    --      commit) ----
    display_w_keep <= display_w;
    display_h_keep <= display_h;
    fb_en_keep     <= fb_en;
    avl_rd_keep    <= avl_readdata;
    avl_rdv_keep   <= avl_readdatavalid;
    avl_wr_keep    <= avl_waitrequest;

    -- ---- DDR3 outputs tied off (no traffic yet) ----
    avl_address    <= (others => '0');
    avl_burstcount <= (others => '0');
    avl_writedata  <= (others => '0');
    avl_byteenable <= (others => '0');
    avl_write      <= '0';
    avl_read       <= '0';

end architecture;
