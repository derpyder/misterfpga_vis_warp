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

    -- ---- Firmware-writable, RTL-ignored regs ----
    -- vis_warp_v2 stage 4 (edfffe1) does NOT expose runtime ports for
    -- bilinear_en or curvature_k -- they are still compile-time generics
    -- (curvature) or always-on (bilinear). Agent C's firmware writes them
    -- via cmd 0x45 opcodes 000[1] and 001[2:0]; we hold them here so the
    -- HPS_BUS contract is preserved and a future v2 revision can pick
    -- them up without firmware changes.
    --
    -- Quartus attributes "keep" + "noprune" together keep the register
    -- storage and prevent dead-code elimination at the netlist level.
    -- (GHDL ignores both, which is fine -- sim doesn't strip signals.)
    attribute keep    : boolean;
    attribute noprune : boolean;
    attribute keep    of reg_bilinear  : signal is true;
    attribute keep    of reg_curvature : signal is true;
    attribute noprune of reg_bilinear  : signal is true;
    attribute noprune of reg_curvature : signal is true;

    -- Derived bloom_mix_q8: firmware writes only reg_bloom_gain (Q0.4) via
    -- opcode 0x010 -- there's no separate mix slider in the OSD yet. We
    -- promote the same value to Q0.8 by left-shifting 4 bits so the lerp-
    -- mode (bloom_mode=01) gets a non-trivial mix factor driven from the
    -- same UI control as max-blend gain. Once firmware adds a 5th opcode
    -- with its own mix payload, this derivation goes away.
    signal bloom_mix_q8 : std_logic_vector(7 downto 0);

    -- scanlines port: gate density through enable so v2 sees canonical
    -- "00" (Off) when reg_scan_en='0', matching A's port semantics.
    signal v2_scanlines : std_logic_vector(1 downto 0);

    signal display_w_keep : std_logic_vector(11 downto 0);
    signal display_h_keep : std_logic_vector(11 downto 0);

    -- ---- fb_en bypass plumbing ----
    -- When fb_en='1' (MISTER_FB cores like N64) the core has already
    -- rendered a framebuffer; ascal reads it directly and vis_warp must
    -- be invisible. We implement bypass at the WRAPPER level so it is
    -- guaranteed independent of whatever v2 is doing internally. The
    -- 1-cycle latch matches the stub's original passthrough timing.
    signal bypass_dout       : std_logic_vector(23 downto 0) := (others => '0');
    signal bypass_hs_out     : std_logic := '0';
    signal bypass_vs_out     : std_logic := '0';
    signal bypass_de_out     : std_logic := '0';
    signal bypass_ce_pix_out : std_logic := '0';

    -- ---- Component declaration for v2 (matches A's stage 4 entity) ----
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

            -- Runtime FX controls (stage 4 contract)
            warp_en       : in  std_logic;
            bloom_en      : in  std_logic;
            bloom_mode    : in  unsigned(1 downto 0);
            bloom_mix_q8  : in  unsigned(7 downto 0);
            bloom_gain    : in  unsigned(3 downto 0);
            scanlines     : in  unsigned(1 downto 0);

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

    -- Derive bloom_mix_q8 from reg_bloom_gain (Q0.4 -> Q0.8 by <<4).
    -- See "Firmware-writable, RTL-ignored regs" block above for rationale.
    bloom_mix_q8 <= reg_bloom_gain & "0000";

    -- Gate scan density through enable: when reg_scan_en='0', v2 sees
    -- canonical "00" (Off) regardless of what density was last written.
    v2_scanlines <= reg_scan_dens when reg_scan_en = '1' else "00";

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
            warp_en      => reg_enable,
            bloom_en     => reg_bloom_en,
            bloom_mode   => unsigned(reg_bloom_mode),
            bloom_mix_q8 => unsigned(bloom_mix_q8),
            bloom_gain   => unsigned(reg_bloom_gain),
            scanlines    => unsigned(v2_scanlines),

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

    -- ---- fb_en bypass: clk_in passthrough mirroring the old stub ----
    process(clk_in)
    begin
        if rising_edge(clk_in) then
            if ce_pix_in = '1' then
                bypass_dout   <= din;
                bypass_hs_out <= hs_in;
                bypass_vs_out <= vs_in;
                bypass_de_out <= de_in;
            end if;
            bypass_ce_pix_out <= ce_pix_in;
        end if;
    end process;

    -- ---- Output MUX: fb_en selects between v2 and the bypass latch ----
    -- fb_en is on clk_sys but we treat it as a slow-changing config bit
    -- here; for HW, fb_en is held stable for the duration of a MISTER_FB
    -- frame, so a glitch-free combinatorial mux is fine. If timing
    -- closure flags this path it becomes one of the B4 CDC cleanups.
    dout       <= bypass_dout       when fb_en = '1' else v2_dout;
    ce_pix_out <= bypass_ce_pix_out when fb_en = '1' else v2_ce_pix_out;
    hs_out     <= bypass_hs_out     when fb_en = '1' else v2_hs_out;
    vs_out     <= bypass_vs_out     when fb_en = '1' else v2_vs_out;
    de_out     <= bypass_de_out     when fb_en = '1' else v2_de_out;

    -- ---- Lint hygiene ----
    -- All control regs except reg_bilinear and reg_curvature now feed real
    -- v2 ports. Those two carry keep_signal attributes (see declarations
    -- above) so Quartus retains the register storage even though no
    -- consumer exists today.
    -- display_w/h are still wrapper-only (v2 uses compile-time generics);
    -- keep them alive against synth elimination via the keep signals below.
    display_w_keep <= display_w;
    display_h_keep <= display_h;

end architecture;
