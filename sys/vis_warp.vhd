-- vis_warp -- MiSTer framework video FX wrapper (Phase 2 warp-as-parent)
--
-- ARCHITECTURE (post-2026-05-26 reset):
--   - vis_warp is the OUTERMOST stage of the framework's video pipeline.
--     ascal/shadowmask/osd all run UPSTREAM in sys_top.v; this wrapper
--     sits at site A (post-osd hdmi_osd, pre-csync, clk_hdmi domain).
--   - Streaming path is single-clock: clk_in == clk_out == clk_hdmi.
--     The wrapper aliases them into v2's single `clk` port.
--   - Wrapper instantiates `vis_warp_v2_wp` (the new small entity in
--     sys/vis_warp_v2_wp.vhd) that does: DDR3 ping-pong capture +
--     readback + barrel-warp sampling. No bloom, no scanlines, no
--     bilinear (ascal already upscales upstream).
--
-- HPS_BUS contract (cmd 0x45 opcodes) is PRESERVED for firmware
-- compatibility (Main_MiSTer-VIS commit be6cb79). Opcode 000 (flags)
-- and 001 (curvature) feed real v2 ports; opcodes 010 (bloom) and 011
-- (scanlines) decode into keep+noprune-attributed dead registers so
-- the firmware can keep emitting them without errors. A future move
-- can re-purpose those opcodes for warp-specific knobs.
--
-- CDC: cmd_wr/cmd_in are clk_sys domain. They cross to clk_hdmi via
-- the control-register latches below (read by v2 on clk_hdmi). For
-- the slow opcode-write rate this is safe as a single-flop crossing;
-- a future move can add a 2-flop synchronizer or the salvaged
-- async_fifo from parked refs if metastability becomes an issue.
--
-- fb_en: under site A, MISTER_FB cores' framebuffers reach this layer
-- post-ascal/osd just like any other source, so fb_en bypass at the
-- wrapper layer no longer makes sense. fb_en is kept on the entity
-- port (= sys_top.v contract) but tied off internally with keep so the
-- pin doesn't optimize out.

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

        -- Source side (now: post-osd in sys_top.v site A wiring)
        ce_pix_in   : in  std_logic;
        din         : in  std_logic_vector(23 downto 0);
        hs_in       : in  std_logic;
        vs_in       : in  std_logic;
        de_in       : in  std_logic;

        -- Sink side (feeds HDMI direct-video mux at sys_top.v:1385)
        ce_pix_out  : out std_logic;
        dout        : out std_logic_vector(23 downto 0);
        hs_out      : out std_logic;
        vs_out      : out std_logic;
        de_out      : out std_logic;

        -- HDMI raster size (post-ascal output dims; sys_top wiring)
        display_w   : in  std_logic_vector(11 downto 0);
        display_h   : in  std_logic_vector(11 downto 0);

        -- MISTER_FB bypass marker (unused under warp-as-parent)
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

    -- Keep fb_en alive even though wrapper ignores it under site A.
    attribute keep    : boolean;
    attribute noprune : boolean;
    attribute keep    of fb_en : signal is true;
    attribute noprune of fb_en : signal is true;
end entity;

architecture wrapper of vis_warp is

    -- ---- Opcode encoding (must match firmware setVisWarp) ----
    constant OP_FLAGS     : std_logic_vector(2 downto 0) := "000";
    constant OP_CURVATURE : std_logic_vector(2 downto 0) := "001";
    constant OP_BLOOM     : std_logic_vector(2 downto 0) := "010";  -- kept for FW compat
    constant OP_SCANLINES : std_logic_vector(2 downto 0) := "011";  -- kept for FW compat

    -- ---- Control registers (clk_sys domain) ----
    -- LIVE (feed real v2 ports):
    signal reg_enable     : std_logic := '0';                       -- flags[0] -> warp_en
    signal reg_curvature  : std_logic_vector(2 downto 0) := "000";  -- -> curvature_k
    -- DEAD-BUT-KEPT (preserve HPS_BUS contract; not consumed by v2):
    signal reg_bilinear   : std_logic := '0';
    signal reg_bloom_en   : std_logic := '0';
    signal reg_scan_en    : std_logic := '0';
    signal reg_bloom_mode : std_logic_vector(1 downto 0) := "00";
    signal reg_bloom_gain : std_logic_vector(3 downto 0) := "0000";
    signal reg_scan_dens  : std_logic_vector(1 downto 0) := "00";
    signal reg_reset_int  : std_logic := '0';

    -- Keep the dead regs from getting optimized out (so a future move
    -- can wire them somewhere without disturbing the firmware contract).
    -- attribute keep/noprune are declared in the entity scope and are
    -- visible here without redeclaration.
    attribute keep    of reg_bilinear   : signal is true;
    attribute keep    of reg_bloom_en   : signal is true;
    attribute keep    of reg_scan_en    : signal is true;
    attribute keep    of reg_bloom_mode : signal is true;
    attribute keep    of reg_bloom_gain : signal is true;
    attribute keep    of reg_scan_dens  : signal is true;
    attribute noprune of reg_bilinear   : signal is true;
    attribute noprune of reg_bloom_en   : signal is true;
    attribute noprune of reg_scan_en    : signal is true;
    attribute noprune of reg_bloom_mode : signal is true;
    attribute noprune of reg_bloom_gain : signal is true;
    attribute noprune of reg_scan_dens  : signal is true;

    -- v2 reset is driven by the OP=111 reset_internal pulse.
    signal v2_reset : std_logic;

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

    v2_reset <= reg_reset_int;

    -- ---- v2 instance (direct entity reference; no component decl) ----
    -- Under site A, clk_in and clk_out are the SAME (= clk_hdmi). We
    -- alias clk_in into v2's single clk port. clk_out is ignored at
    -- this layer (the entity port stays for sys_top contract).
    u_v2 : entity work.vis_warp_v2_wp
        generic map (
            MAX_DST_W   => 1920,
            MAX_DST_H   => 1080,
            AW          => AW,
            DW          => DW,
            BEW         => BEW,
            BCW         => BCW,
            BANK_A_BASE => 16#2080000#,
            BANK_B_BASE => 16#2100000#,
            READ_LAT    => 8,
            -- HDMI raster blanking. Real HDMI has much larger HBLANK
            -- (typically ~280 cycles for 1920x1080), but the v2 read-
            -- side raster generates its own; sys_top.v feeds the real
            -- sync into v2 via hs_in/vs_in/de_in, but v2 currently
            -- regens its own sync from the counter. Move 6.4-ish
            -- decision: either trust sys_top sync (pass through) or
            -- regen here. For first integration, keep small defaults
            -- and trust the counter walk to align with HDMI rate.
            HBLANK      => 16,
            VBLANK      => 4
        )
        port map (
            clk         => clk_in,         -- = clk_hdmi under site A
            reset       => v2_reset,

            warp_en     => reg_enable,
            curvature_k => unsigned(reg_curvature),

            dst_w       => unsigned(display_w),
            dst_h       => unsigned(display_h),

            ce_pix_in   => ce_pix_in,
            din         => din,
            hs_in       => hs_in,
            vs_in       => vs_in,
            de_in       => de_in,

            ce_pix_out  => ce_pix_out,
            dout        => dout,
            hs_out      => hs_out,
            vs_out      => vs_out,
            de_out      => de_out,

            avl_address       => avl_address,
            avl_burstcount    => avl_burstcount,
            avl_writedata     => avl_writedata,
            avl_byteenable    => avl_byteenable,
            avl_write         => avl_write,
            avl_read          => avl_read,
            avl_readdata      => avl_readdata,
            avl_readdatavalid => avl_readdatavalid,
            avl_waitrequest   => avl_waitrequest
        );

end architecture;
