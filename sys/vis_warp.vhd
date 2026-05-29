-- vis_warp -- MiSTer framework video FX wrapper (Phase 2 site-C edition)
--
-- ARCHITECTURE (post-2026-05-27 final): site C, pre-ascal, source res.
--   See ~/.claude/projects/D--deck/memory/design_vis_warp_constraints.md
--   for the locked-in architectural rationale. tl;dr: vis_warp lives
--   between the game core's raw output and ascal's input, on clk_video
--   (the game's pixel clock), at source resolution. Avoids vbuf
--   sharing with ascal, avoids clk_video <-> clk_hdmi CDC, avoids
--   warping the OSD overlay, and lets the bow scale naturally with
--   whatever integer-scaled HDMI mode ascal upscales to (1080p, 4K, etc).
--
-- HPS_BUS contract (cmd 0x45 opcodes) is PRESERVED for firmware
-- compatibility (Main_MiSTer-VIS commit be6cb79). Opcodes 000 (flags)
-- and 001 (curvature) feed real v2 ports; opcodes 010 (bloom) and 011
-- (scanlines) latch into keep+noprune-attributed dead registers so the
-- firmware can keep emitting them without errors. A future move can
-- re-purpose those opcodes for warp-specific knobs (intensity, edge
-- softness, etc.).
--
-- CDC: cmd_wr/cmd_in are clk_sys domain. The clk_sys-domain control
-- registers (reg_enable, reg_curvature, v2_reset pulse) cross to clk_in
-- (= clk_video) via the synchronizers below.
--
-- B4 Phase 1 minimal CDC (2026-05-28, SPEC-vis_warp-v3.md):
--   * reg_enable and reg_curvature are LEVEL signals → simple 2-flop
--     sync per bit. A 1-cycle transient mid-update is harmless because
--     v2 will use whichever value at next clock and the user-side OSD
--     interaction is slow vs pixel rate.
--   * v2_reset is a 1-cycle PULSE on clk_sys → converted to a toggle
--     on clk_sys, 2-flop synced to clk_in, edge-detected (xor) to
--     regenerate a 1-cycle pulse on clk_in. Pulse cannot be lost
--     regardless of clk_sys vs clk_in ratio.
-- B4 Phase 2 (async dcfifo) is deferred per spec: at site C
--   clk_out = clk_in = clk_ihdmi, so the egress crossing collapses and
--   the data path stays entirely on clk_in inside vis_warp_v2_wp.
-- TODO (open question #1 in spec): if Quartus reports unconstrained
-- paths on the sync signals, add a vis_warp.sdc with set_false_path
-- entries; do not edit Template.sdc (upstream-tracked).
--
-- Port shape CHANGED from prior DDR3-based design:
--   - Dropped: avl_* ports (vbuf access), AW/DW/BEW/BCW generics,
--     display_w / display_h (v2 auto-detects source dims), fb_en
--     (irrelevant at site C since MISTER_FB cores' framebuffers also
--     route through this layer pre-ascal).
--   - 24-bit din/dout split into 8-bit r/g/b to match ascal's input
--     port shape (i_r, i_g, i_b each 8 bits).
--   - clk_in is still passed in (= clk_video at site C). clk_out kept
--     on the entity for sys_top contract compatibility but unused.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vis_warp is
    port (
        clk_sys     : in  std_logic;
        clk_in      : in  std_logic;     -- = clk_video at site C
        clk_out     : in  std_logic;     -- unused at site C; kept for contract

        -- HPS_BUS config (UIO 0x45)
        cmd_wr      : in  std_logic;
        cmd_in      : in  std_logic_vector(15 downto 0);

        -- Source side (= raw emu output, pre-ascal under site C wiring)
        ce_pix_in   : in  std_logic;
        r_in        : in  std_logic_vector(7 downto 0);
        g_in        : in  std_logic_vector(7 downto 0);
        b_in        : in  std_logic_vector(7 downto 0);
        hs_in       : in  std_logic;
        vs_in       : in  std_logic;
        de_in       : in  std_logic;

        -- Sink side (= feeds ascal's i_r/i_g/i_b/i_hs/i_vs/i_de inputs)
        ce_pix_out  : out std_logic;
        r_out       : out std_logic_vector(7 downto 0);
        g_out       : out std_logic_vector(7 downto 0);
        b_out       : out std_logic_vector(7 downto 0);
        hs_out      : out std_logic;
        vs_out      : out std_logic;
        de_out      : out std_logic
    );
end entity;

architecture wrapper of vis_warp is

    -- ---- Opcode encoding (must match firmware setVisWarp) ----
    constant OP_FLAGS     : std_logic_vector(2 downto 0) := "000";
    constant OP_CURVATURE : std_logic_vector(2 downto 0) := "001";
    constant OP_BLOOM     : std_logic_vector(2 downto 0) := "010";  -- kept for FW compat
    constant OP_SCANLINES : std_logic_vector(2 downto 0) := "011";  -- kept for FW compat

    -- ---- Control registers (clk_sys domain) ----
    -- LIVE (feed real v2 ports):
    --
    -- Development-time defaults (no Main_MiSTer userland yet — task v4):
    --   Phase 3 baseline (MISTER_WARP unset):     irrelevant, vis_warp not built
    --   Phase 4 MISTER_WARP, identity (k=0):     reg_enable := '1', reg_curvature := "000"
    --   Phase 5 visible bow (k=2):               reg_enable := '1', reg_curvature := "010"
    --   Phase 6 unmissable bow (k=7):            reg_enable := '1', reg_curvature := "111"
    -- Edit the two initializers below per phase; hardware will see the
    -- new defaults at reset. HPS-driven dynamic control comes with the
    -- v4 Main_MiSTer userland PR.
    signal reg_enable     : std_logic := '1';                       -- ENABLED for Phase 4 test
    signal reg_curvature  : std_logic_vector(2 downto 0) := "010";  -- k=2
    -- LIVE (v3.1 — bilinear pixel fetch in vis_warp_v2_wp):
    -- Default '1' for Phase 5 default-on dev-time testing; HPS-driven
    -- runtime control comes with the v4 Main_MiSTer userland PR.
    signal reg_bilinear   : std_logic := '1';
    -- LIVE (v3.3d — sharp-bilinear sharpness K), opcode 010 (was bloom).
    -- "001"=K1 soft/pure-bilinear, "010"=K2 default, "011".."111"=sharper
    -- toward nearest-neighbor. v4 OSD "Warp Sharpness" drives this live;
    -- dev-tuned to 4 (sharper) until then. Mirrors reg_curvature's runtime-reg
    -- mechanism exactly.
    signal reg_sharpness  : std_logic_vector(2 downto 0) := "100";  -- K=4 (dev-tuned sharp)
    -- DEAD-BUT-KEPT (preserve HPS_BUS contract; not consumed by v2):
    signal reg_bloom_en   : std_logic := '0';
    signal reg_scan_en    : std_logic := '0';
    signal reg_bloom_mode : std_logic_vector(1 downto 0) := "00";
    signal reg_bloom_gain : std_logic_vector(3 downto 0) := "0000";
    signal reg_scan_dens  : std_logic_vector(1 downto 0) := "00";
    signal reg_reset_int  : std_logic := '0';

    attribute keep    : boolean;
    attribute noprune : boolean;
    -- reg_bilinear is now LIVE (v3.1), so it no longer needs keep/noprune
    -- to survive optimization — it's consumed by the v2 instance below.
    attribute keep    of reg_bloom_en   : signal is true;
    attribute keep    of reg_scan_en    : signal is true;
    attribute keep    of reg_bloom_mode : signal is true;
    attribute keep    of reg_bloom_gain : signal is true;
    attribute keep    of reg_scan_dens  : signal is true;
    attribute noprune of reg_bloom_en   : signal is true;
    attribute noprune of reg_scan_en    : signal is true;
    attribute noprune of reg_bloom_mode : signal is true;
    attribute noprune of reg_bloom_gain : signal is true;
    attribute noprune of reg_scan_dens  : signal is true;

    -- v2 reset is driven by the OP=111 reset_internal pulse, converted
    -- to a toggle on clk_sys and edge-detected on clk_in (see below).
    signal v2_reset_sync : std_logic;

    -- ---- CDC synchronizers (B4 Phase 1 minimal, clk_sys -> clk_in) ----
    -- See the architecture-level comment at the top of this file.
    signal reset_toggle_src   : std_logic := '0';
    signal reset_toggle_s1    : std_logic := '0';
    signal reset_toggle_s2    : std_logic := '0';
    signal reset_toggle_s3    : std_logic := '0';
    signal reg_enable_s1      : std_logic := '0';
    signal reg_enable_s2      : std_logic := '0';
    signal reg_curvature_s1   : std_logic_vector(2 downto 0) := "000";
    signal reg_curvature_s2   : std_logic_vector(2 downto 0) := "000";
    signal reg_sharpness_s1   : std_logic_vector(2 downto 0) := "010";
    signal reg_sharpness_s2   : std_logic_vector(2 downto 0) := "010";
    signal reg_bilinear_s1    : std_logic := '0';
    signal reg_bilinear_s2    : std_logic := '0';

    -- Tell Quartus not to optimize the synchronizer chains.
    attribute preserve : boolean;
    attribute preserve of reset_toggle_s1  : signal is true;
    attribute preserve of reset_toggle_s2  : signal is true;
    attribute preserve of reset_toggle_s3  : signal is true;
    attribute preserve of reg_enable_s1    : signal is true;
    attribute preserve of reg_enable_s2    : signal is true;
    attribute preserve of reg_curvature_s1 : signal is true;
    attribute preserve of reg_curvature_s2 : signal is true;
    attribute preserve of reg_sharpness_s1 : signal is true;
    attribute preserve of reg_sharpness_s2 : signal is true;
    attribute preserve of reg_bilinear_s1  : signal is true;
    attribute preserve of reg_bilinear_s2  : signal is true;

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
                    when OP_BLOOM =>   -- v3.3d: opcode 010 repurposed bloom → sharpness
                        reg_sharpness <= v_payload(2 downto 0);
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

    -- ---- Convert reset pulse to toggle (clk_sys) ----
    -- The cmd-decoder above produces reg_reset_int as a 1-cycle pulse on
    -- clk_sys. Toggle on each pulse so the clk_in side can recover the
    -- event via XOR edge-detection regardless of clk ratios.
    process(clk_sys)
    begin
        if rising_edge(clk_sys) then
            if reg_reset_int = '1' then
                reset_toggle_src <= not reset_toggle_src;
            end if;
        end if;
    end process;

    -- ---- 2-flop synchronizers (clk_in) ----
    process(clk_in)
    begin
        if rising_edge(clk_in) then
            -- level signals (2-flop each)
            reg_enable_s1    <= reg_enable;
            reg_enable_s2    <= reg_enable_s1;
            reg_curvature_s1 <= reg_curvature;
            reg_curvature_s2 <= reg_curvature_s1;
            reg_sharpness_s1 <= reg_sharpness;
            reg_sharpness_s2 <= reg_sharpness_s1;
            reg_bilinear_s1  <= reg_bilinear;
            reg_bilinear_s2  <= reg_bilinear_s1;
            -- reset toggle (3-flop so we can XOR _s2 ^ _s3 = 1-cycle pulse)
            reset_toggle_s1  <= reset_toggle_src;
            reset_toggle_s2  <= reset_toggle_s1;
            reset_toggle_s3  <= reset_toggle_s2;
        end if;
    end process;

    -- Edge-detect the synchronized toggle into a single-cycle clk_in pulse.
    v2_reset_sync <= reset_toggle_s2 xor reset_toggle_s3;

    -- ---- v2 instance ----
    -- All on clk_in (= clk_video). At site C this is the game core's
    -- pixel clock; ascal's i_clk is the same wire. All control signals
    -- entering v2 are clk_in-synchronized per B4 Phase 1.
    u_v2 : entity work.vis_warp_v2_wp
        generic map (
            MAX_SRC_W => 512,
            N_LINES   => 128
        )
        port map (
            clk         => clk_in,
            reset       => v2_reset_sync,

            warp_en     => reg_enable_s2,
            curvature_k => unsigned(reg_curvature_s2),
            sharpness   => unsigned(reg_sharpness_s2),
            bilinear_en => reg_bilinear_s2,

            ce_pix      => ce_pix_in,

            r_in        => r_in,
            g_in        => g_in,
            b_in        => b_in,
            hs_in       => hs_in,
            vs_in       => vs_in,
            de_in       => de_in,

            r_out       => r_out,
            g_out       => g_out,
            b_out       => b_out,
            hs_out      => hs_out,
            vs_out      => vs_out,
            de_out      => de_out
        );

    -- ce_pix_out passes through (the pipeline is ce_pix-gated, so the
    -- output's effective pixel-clock-enable matches the input).
    ce_pix_out <= ce_pix_in;

end architecture;
