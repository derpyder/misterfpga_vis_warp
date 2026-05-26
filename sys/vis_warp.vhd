-- vis_warp -- MiSTer framework video FX module (Phase 2 framework wrapper)
--
-- This file is the framework-facing wrapper. It bridges the LOCKED port
-- contract that sys_top.v drives into the variable-shape implementation
-- entity vis_warp_v2 (which Agent A is iterating on under
-- D:\deck\fpga\pacman-vis\sim\rtl\). The framework contract is:
--
--   - clk_sys      : config clock (cmd_wr / cmd_in run on this)
--   - clk_in       : source pixel clock (= clk_vid in sys_top)
--   - clk_out      : sink pixel clock   (= clk_hdmi in sys_top, scaler input)
--   - cmd_wr/cmd_in: HPS_BUS write port for runtime config (UIO 0x45),
--                    SIXTEEN BITS WIDE -- matches Agent C's firmware
--                    (Main_MiSTer-VIS commit be6cb79).
--   - din/dout     : 24bpp RGB888
--   - hs/vs/de     : sync forwarding (input + output, may have CDC delay)
--   - display_w/h  : output frame size
--   - fb_en        : MISTER_FB bypass (handled by this wrapper, not v2)
--   - vbuf         : Avalon-MM port to DDR3 vbuf channel (shared with
--                    ascal via vbuf_svc arbiter)
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
-- CDC: vis_warp_v2 (sim today) is single-clock. On real HW the engine
-- will run on clk_sys while video crosses clk_in -> clk_out. Phase 2.5
-- milestone B4 will add dcfifo CDCs between domains; for now we drive v2's
-- single clk from clk_sys. Control registers latch on clk_sys (same
-- domain as cmd_wr) so they're already in the right domain to feed v2's
-- static control inputs once Agent A exposes them.

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

    -- ---- Control registers (clk_sys domain) ----
    signal reg_enable     : std_logic := '0';                       -- flags[0] warp_en
    signal reg_bilinear   : std_logic := '0';                       -- flags[1]
    signal reg_bloom_en   : std_logic := '0';                       -- flags[2]
    signal reg_scan_en    : std_logic := '0';                       -- flags[3]
    signal reg_curvature  : std_logic_vector(2 downto 0) := "000";
    signal reg_bloom_mode : std_logic_vector(1 downto 0) := "00";
    signal reg_bloom_gain : std_logic_vector(3 downto 0) := "0000";
    signal reg_scan_dens  : std_logic_vector(1 downto 0) := "00";
    signal reg_reset_int  : std_logic := '0';

    -- ---- v2 instance signals ----
    signal v2_din        : std_logic_vector(23 downto 0);
    signal v2_ce_pix_in  : std_logic;
    signal v2_hs_in      : std_logic;
    signal v2_vs_in      : std_logic;
    signal v2_de_in      : std_logic;

    signal v2_dout       : std_logic_vector(23 downto 0);
    signal v2_ce_pix_out : std_logic;
    signal v2_hs_out     : std_logic;
    signal v2_vs_out     : std_logic;
    signal v2_de_out     : std_logic;

    signal v2_reset      : std_logic;

    signal v2_dbg_x      : integer;
    signal v2_dbg_y      : integer;

    -- Lint keepers for control bits not yet consumed by v2 (the gap list:
    -- bilinear, bloom_en, bloom_mode, bloom_gain, scan_en, scan_dens,
    -- curvature). Wrapper still HOLDS them; B3 wires them once Agent A's
    -- stage 4 adds the corresponding v2 input ports.
    signal ctl_keep      : std_logic_vector(15 downto 0);

    signal display_w_keep : std_logic_vector(11 downto 0);
    signal display_h_keep : std_logic_vector(11 downto 0);
    signal fb_en_keep     : std_logic;

    -- ---- Component declaration for v2 (uses positional? no, named) ----
    component vis_warp_v2 is
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
            BANK_A_BASE : integer := 16#2080000#;
            BANK_B_BASE : integer := 16#2100000#
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
    end component;

begin

    -- ---- Command decoder (clk_sys) ----
    process(clk_sys)
        variable v_op      : std_logic_vector(2 downto 0);
        variable v_payload : std_logic_vector(12 downto 0);
    begin
        if rising_edge(clk_sys) then
            reg_reset_int <= '0';
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
                        reg_bloom_mode <= v_payload(12 downto 11);
                        reg_bloom_gain <= v_payload(10 downto 7);
                    when OP_SCANLINES =>
                        reg_scan_dens <= v_payload(12 downto 11);
                    when "111" =>
                        reg_reset_int <= '1';
                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- ---- v2 instance ----
    -- For the moment v2 sees the raw framework video stream. fb_en bypass
    -- (commit 3 of this milestone) will gate this; today the wrapper has
    -- no bypass yet so v2 runs unconditionally.
    v2_din       <= din;
    v2_ce_pix_in <= ce_pix_in;
    v2_hs_in     <= hs_in;
    v2_vs_in     <= vs_in;
    v2_de_in     <= de_in;

    -- v2 reset is driven by either the wrapper's external reset (none today)
    -- or the OP=111 reset_internal pulse from the command decoder.
    v2_reset <= reg_reset_int;

    -- vis_warp_v2 generics: SRC_W/SRC_H/DST_W/DST_H are integer-only in v2's
    -- entity, so we must pass compile-time constants. display_w/display_h
    -- are 12-bit runtime signals -- they can't drive generics. DESIGN-
    -- phase2-ddr3.md doesn't lock DST to a single value either, but for
    -- the framework defaults we pin to Pac-Man's 288x224 source / 288x224
    -- 1:1 dst (matches v2's default generics). Per-core overrides land
    -- alongside DESIGN's "source_dims" opcode (100) in a future milestone.
    --
    -- The 12-bit runtime display_w/display_h are kept on the wrapper
    -- entity so the contract with sys_top stays unchanged; they're just
    -- not consumed by the v2 of today.
    u_v2 : vis_warp_v2
        generic map (
            SRC_W       => 288,
            SRC_H       => 224,
            DST_W       => 288,
            DST_H       => 224,
            ARX         => 2880,
            ARY         => 2219,
            AW          => AW,
            DW          => DW,
            BEW         => BEW,
            BCW         => BCW,
            BANK_A_BASE => 16#2080000#,   -- byte 0x20800000 / 16 (word addr)
            BANK_B_BASE => 16#2100000#    -- byte 0x21000000 / 16
        )
        port map (
            clk         => clk_sys,        -- single-clock for now; B4 fixes
            reset       => v2_reset,
            warp_en     => reg_enable,

            ce_pix_in   => v2_ce_pix_in,
            din         => v2_din,
            hs_in       => v2_hs_in,
            vs_in       => v2_vs_in,
            de_in       => v2_de_in,

            ce_pix_out  => v2_ce_pix_out,
            dout        => v2_dout,
            hs_out      => v2_hs_out,
            vs_out      => v2_vs_out,
            de_out      => v2_de_out,

            avl_address       => avl_address,
            avl_burstcount    => avl_burstcount,
            avl_writedata     => avl_writedata,
            avl_byteenable    => avl_byteenable,
            avl_write         => avl_write,
            avl_read          => avl_read,
            avl_readdata      => avl_readdata,
            avl_readdatavalid => avl_readdatavalid,
            avl_waitrequest   => avl_waitrequest,

            dbg_cnt_x_o => v2_dbg_x,
            dbg_cnt_y_o => v2_dbg_y
        );

    -- ---- Wrapper outputs come straight from v2 (fb_en bypass added next
    --      commit; today wrapper = v2 unconditionally) ----
    dout       <= v2_dout;
    ce_pix_out <= v2_ce_pix_out;
    hs_out     <= v2_hs_out;
    vs_out     <= v2_vs_out;
    de_out     <= v2_de_out;

    -- ---- Lint hygiene -- bundle unused control regs together so a single
    --      OR keeps them alive; same trick for unused inputs. These all go
    --      away (replaced by real wiring) when Agent A exposes the missing
    --      v2 input ports. ----
    ctl_keep <= "00000000"
              & reg_bilinear
              & reg_bloom_en
              & reg_scan_en
              & reg_bloom_mode
              & reg_scan_dens(0)
              & reg_curvature(0);

    display_w_keep <= display_w;
    display_h_keep <= display_h;
    fb_en_keep     <= fb_en;

end architecture;
