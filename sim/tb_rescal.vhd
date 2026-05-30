-- tb_rescal.vhd -- focused testbench for vis_warp_rescal.
-- Drives the 4 golden resolutions and asserts AX2/AY2 == the validated values
-- (warp_prototype.py / HANDOFF-cylindrical-warp). Run:
--   GH=/c/Users/mattl/bin/ghdl/bin/ghdl.exe
--   WD=.../sim/ghdl_work
--   "$GH" -a --std=08 --workdir="$WD" sys/vis_warp_rescal.vhd sim/tb_rescal.vhd
--   "$GH" -e --std=08 --workdir="$WD" tb_rescal
--   "$GH" -r --std=08 --workdir="$WD" tb_rescal --stop-time=50us
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_rescal is
end entity;

architecture sim of tb_rescal is
    signal clk   : std_logic := '0';
    signal start : std_logic := '0';
    signal src_w : unsigned(11 downto 0) := (others => '0');
    signal src_h : unsigned(11 downto 0) := (others => '0');
    signal ax2   : unsigned(12 downto 0);
    signal ay2   : unsigned(12 downto 0);
    signal done  : std_logic;
    signal stop  : boolean := false;
begin
    dut : entity work.vis_warp_rescal
        port map (clk => clk, start => start, src_w => src_w, src_h => src_h,
                  ax2 => ax2, ay2 => ay2, done => done);

    clkproc : process
    begin
        while not stop loop
            clk <= '0'; wait for 5 ns;
            clk <= '1'; wait for 5 ns;
        end loop;
        wait;
    end process;

    stim : process
        variable err : integer := 0;
        procedure check(w, h, ew, eh : integer) is
        begin
            src_w <= to_unsigned(w, 12);
            src_h <= to_unsigned(h, 12);
            wait until rising_edge(clk);
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';
            wait until done = '1';
            wait until rising_edge(clk);   -- outputs are stable (held after S_DONE)
            report "res " & integer'image(w) & "x" & integer'image(h) &
                   " -> AX2=" & integer'image(to_integer(ax2)) &
                   " AY2=" & integer'image(to_integer(ay2)) &
                   " (expect " & integer'image(ew) & "/" & integer'image(eh) & ")";
            if to_integer(ax2) /= ew or to_integer(ay2) /= eh then
                report "  MISMATCH at " & integer'image(w) & "x" & integer'image(h)
                    severity error;
                err := err + 1;
            end if;
        end procedure;
    begin
        wait for 20 ns;
        check(288, 224, 508, 498);
        check(480, 360, 188, 184);
        check(640, 480, 106, 104);
        check(320, 240, 422, 414);
        -- a re-trigger with unchanged dims must reproduce the same result
        check(320, 240, 422, 414);
        if err = 0 then
            report "ALL GOLDENS PASS" severity note;
        else
            report integer'image(err) & " GOLDEN MISMATCH(ES)" severity failure;
        end if;
        stop <= true;
        wait;
    end process;
end architecture;
