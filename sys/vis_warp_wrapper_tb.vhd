-- vis_warp wrapper smoke testbench
--
-- Lives in sys/ but is NOT added to sys.qip -- it's a local lint/sim
-- helper only. Run with:
--   ghdl -a --std=08 sys/vis_warp_v2.vhd sys/vis_warp.vhd sys/vis_warp_wrapper_tb.vhd
--   ghdl -r --std=08 vis_warp_wrapper_tb
--
-- Exercises:
--   * 4-opcode cmd 0x45 decode (flags / curvature / bloom / scanlines)
--   * reset_internal pulse (opcode 111)
--   * fb_en passthrough bypass
--   * v2-path passthrough (since today's v2 is a stand-in passthrough)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vis_warp_wrapper_tb is
end entity;

architecture sim of vis_warp_wrapper_tb is
    constant CLK_PERIOD : time := 10 ns;
    constant AW : integer := 28;
    constant DW : integer := 128;
    constant BEW : integer := 16;
    constant BCW : integer := 8;

    signal clk_sys     : std_logic := '0';
    signal clk_in      : std_logic := '0';
    signal clk_out     : std_logic := '0';

    signal cmd_wr      : std_logic := '0';
    signal cmd_in      : std_logic_vector(15 downto 0) := (others => '0');

    signal ce_pix_in   : std_logic := '0';
    signal din         : std_logic_vector(23 downto 0) := (others => '0');
    signal hs_in       : std_logic := '0';
    signal vs_in       : std_logic := '0';
    signal de_in       : std_logic := '0';

    signal ce_pix_out  : std_logic;
    signal dout        : std_logic_vector(23 downto 0);
    signal hs_out      : std_logic;
    signal vs_out      : std_logic;
    signal de_out      : std_logic;

    signal display_w   : std_logic_vector(11 downto 0) := x"120";  -- 288
    signal display_h   : std_logic_vector(11 downto 0) := x"0E0";  -- 224
    signal fb_en       : std_logic := '0';

    signal avl_address       : std_logic_vector(AW - 1 downto 0);
    signal avl_burstcount    : std_logic_vector(BCW - 1 downto 0);
    signal avl_writedata     : std_logic_vector(DW - 1 downto 0);
    signal avl_byteenable    : std_logic_vector(BEW - 1 downto 0);
    signal avl_write         : std_logic;
    signal avl_read          : std_logic;
    signal avl_readdata      : std_logic_vector(DW - 1 downto 0) := (others => '0');
    signal avl_readdatavalid : std_logic := '0';
    signal avl_waitrequest   : std_logic := '0';

    signal stop_clocks : boolean := false;

    -- Build a cmd word: opcode in [15:13], payload in [12:0]
    function cmd_word(op : integer; payload : integer) return std_logic_vector is
        variable r : std_logic_vector(15 downto 0);
    begin
        r := std_logic_vector(to_unsigned(op, 3)) & std_logic_vector(to_unsigned(payload, 13));
        return r;
    end function;

begin

    -- Clocks
    clk_sys_proc : process
    begin
        while not stop_clocks loop
            clk_sys <= '0'; wait for CLK_PERIOD / 2;
            clk_sys <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    clk_in_proc : process
    begin
        while not stop_clocks loop
            clk_in <= '0'; wait for CLK_PERIOD / 2;
            clk_in <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    clk_out_proc : process
    begin
        while not stop_clocks loop
            clk_out <= '0'; wait for CLK_PERIOD / 2;
            clk_out <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- DUT
    dut : entity work.vis_warp
        generic map (
            AW  => AW, DW => DW, BEW => BEW, BCW => BCW
        )
        port map (
            clk_sys     => clk_sys,
            clk_in      => clk_in,
            clk_out     => clk_out,

            cmd_wr      => cmd_wr,
            cmd_in      => cmd_in,

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

            display_w   => display_w,
            display_h   => display_h,
            fb_en       => fb_en,

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

    -- Stimulus
    stim : process
        procedure cmd(op : integer; payload : integer) is
        begin
            wait until rising_edge(clk_sys);
            cmd_in <= cmd_word(op, payload);
            cmd_wr <= '1';
            wait until rising_edge(clk_sys);
            cmd_wr <= '0';
            cmd_in <= (others => '0');
        end procedure;

        procedure pix(c24 : std_logic_vector(23 downto 0)) is
        begin
            wait until rising_edge(clk_in);
            din       <= c24;
            ce_pix_in <= '1';
            de_in     <= '1';
            wait until rising_edge(clk_in);
            ce_pix_in <= '0';
            de_in     <= '0';
        end procedure;
    begin
        wait for 50 ns;

        -- ---- cmd decode round-trip ----
        report "TB: cmd flags op=000 payload=0xF (all FX on)";
        cmd(0, 16#F#);                      -- warp+bilinear+bloom+scanlines all on

        report "TB: cmd curvature op=001 K=5";
        cmd(1, 5);

        report "TB: cmd bloom op=010 mode=1 gain=8";
        -- mode<<11 | gain<<7 = (1<<11) | (8<<7) = 0x800 | 0x400 = 0xC00
        cmd(2, 16#C00#);

        report "TB: cmd scanlines op=011 density=3";
        -- density<<11 = 3<<11 = 0x1800
        cmd(3, 16#1800#);

        report "TB: cmd reset_internal op=111";
        cmd(7, 0);

        wait for 100 ns;

        -- ---- v2-path passthrough (fb_en=0, stand-in is passthrough) ----
        report "TB: v2-path: send 3 pixels, expect them to come out (latency aside)";
        fb_en <= '0';
        pix(x"AABBCC");
        pix(x"112233");
        pix(x"445566");

        wait for 100 ns;

        -- ---- fb_en bypass ----
        report "TB: fb_en=1 bypass: send pixel, expect 1-cycle bypass latch";
        fb_en <= '1';
        pix(x"DEADBE");
        pix(x"CAFEBA");

        wait for 100 ns;

        report "TB: done.";
        stop_clocks <= true;
        wait;
    end process;

end architecture;
