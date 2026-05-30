-- vis_warp_rescal.vhd -- resolution-adaptive aspect-weight calculator
--
-- Removes the 480x360 hardcode. Computes the Q0.24 aspect weights AX2/AY2 so
-- the warp corner hits r2 = 2^24 at ANY detected source resolution:
--
--     AX2 = round( 508 * 2^24 / D )
--     AY2 = round( 498 * 2^24 / D )
--     D   = 508*cx^2 + 498*cy^2,   cx = src_w/2,  cy = src_h/2
--
-- For a 4:3 source the engine's separable cylinder uses (AX2+AY2)*dx^2, and
-- both weights scale as 1/D ~ 1/cx^2, so the warp geometry (and the fixed
-- horizontal fill) stay resolution-invariant once the weights adapt. At
-- 480x360 this reproduces the accepted hand-tuned 188/184 exactly.
--
-- Goldens (rounded): 288x224 -> 508/498 ; 480x360 -> 188/184 ;
--                    640x480 -> 106/104 ; 320x240 -> 422/414.
--
-- Frame-rare: `start` (pulsed on a source-dim change) kicks a sequential
-- restoring divider. It is NOT in the pixel path, so its multi-cycle latency
-- is irrelevant and the per-stage logic meets clk_video timing trivially. The
-- ax2/ay2 outputs hold the last result until the next start->done.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity vis_warp_rescal is
    generic (
        BASE_AX : integer := 508;   -- X numerator weight (matches gen_lut.py)
        BASE_AY : integer := 498    -- Y numerator weight
    );
    port (
        clk    : in  std_logic;
        start  : in  std_logic;                 -- 1-cycle pulse: recompute
        src_w  : in  unsigned(11 downto 0);     -- detected source width
        src_h  : in  unsigned(11 downto 0);     -- detected source height
        ax2    : out unsigned(12 downto 0);     -- Q0.24 X weight
        ay2    : out unsigned(12 downto 0);     -- Q0.24 Y weight
        done   : out std_logic                  -- 1-cycle pulse when ax2/ay2 valid
    );
end entity;

architecture rtl of vis_warp_rescal is
    -- numerators 508*2^24 / 498*2^24 (34-bit) -- built by shift, never a literal
    constant NX : unsigned(34 downto 0) := shift_left(to_unsigned(BASE_AX, 35), 24);
    constant NY : unsigned(34 downto 0) := shift_left(to_unsigned(BASE_AY, 35), 24);

    type state_t is (S_IDLE, S_P1, S_P2, S_P3, S_DIV, S_DONE);
    signal state : state_t := S_IDLE;

    signal cx, cy   : unsigned(11 downto 0) := (others => '0');   -- src/2
    signal cx2, cy2 : unsigned(23 downto 0) := (others => '0');   -- (src/2)^2
    signal denom    : unsigned(31 downto 0) := (others => '0');   -- 508cx2+498cy2

    -- restoring divider state (X and Y divide in parallel: same denom + counter)
    signal rem_x, rem_y : unsigned(31 downto 0) := (others => '0');
    signal dvd_x, dvd_y : unsigned(34 downto 0) := (others => '0');  -- shifted MSB-first
    signal q_x,   q_y   : unsigned(34 downto 0) := (others => '0');
    signal iter         : integer range 0 to 35 := 0;

    -- defaults = 288x224 goldens so the outputs are sane before the first compute
    signal ax2_r  : unsigned(12 downto 0) := to_unsigned(BASE_AX, 13);
    signal ay2_r  : unsigned(12 downto 0) := to_unsigned(BASE_AY, 13);
    signal done_r : std_logic := '0';
begin
    ax2  <= ax2_r;
    ay2  <= ay2_r;
    done <= done_r;

    process(clk)
        variable d33    : unsigned(32 downto 0);
        variable rx, ry : unsigned(32 downto 0);   -- (rem << 1) | next dividend bit
    begin
        if rising_edge(clk) then
            done_r <= '0';
            case state is
                when S_IDLE =>
                    if start = '1' then
                        cx    <= '0' & src_w(11 downto 1);   -- src_w / 2
                        cy    <= '0' & src_h(11 downto 1);   -- src_h / 2
                        state <= S_P1;
                    end if;

                when S_P1 =>
                    cx2   <= resize(cx * cx, 24);
                    cy2   <= resize(cy * cy, 24);
                    state <= S_P2;

                when S_P2 =>
                    -- D = 508*cx2 + 498*cy2 (frame-rare: a plain multiply is fine)
                    denom <= resize(to_unsigned(BASE_AX, 10) * cx2, 32)
                           + resize(to_unsigned(BASE_AY, 10) * cy2, 32);
                    state <= S_P3;

                when S_P3 =>
                    -- round-to-nearest: dividend = N + D/2 ; init the divider
                    dvd_x <= NX + resize(shift_right(denom, 1), 35);
                    dvd_y <= NY + resize(shift_right(denom, 1), 35);
                    rem_x <= (others => '0');
                    rem_y <= (others => '0');
                    q_x   <= (others => '0');
                    q_y   <= (others => '0');
                    iter  <= 0;
                    state <= S_DIV;

                when S_DIV =>
                    -- one restoring-division step (MSB-first), X and Y together
                    d33 := '0' & denom;
                    rx  := rem_x & dvd_x(34);
                    ry  := rem_y & dvd_y(34);
                    if rx >= d33 then
                        rem_x <= resize(rx - d33, 32);
                        q_x   <= q_x(33 downto 0) & '1';
                    else
                        rem_x <= resize(rx, 32);
                        q_x   <= q_x(33 downto 0) & '0';
                    end if;
                    if ry >= d33 then
                        rem_y <= resize(ry - d33, 32);
                        q_y   <= q_y(33 downto 0) & '1';
                    else
                        rem_y <= resize(ry, 32);
                        q_y   <= q_y(33 downto 0) & '0';
                    end if;
                    dvd_x <= dvd_x(33 downto 0) & '0';
                    dvd_y <= dvd_y(33 downto 0) & '0';
                    if iter = 34 then
                        state <= S_DONE;
                    else
                        iter <= iter + 1;
                    end if;

                when S_DONE =>
                    ax2_r  <= q_x(12 downto 0);
                    ay2_r  <= q_y(12 downto 0);
                    done_r <= '1';
                    state  <= S_IDLE;
            end case;
        end if;
    end process;
end architecture;
