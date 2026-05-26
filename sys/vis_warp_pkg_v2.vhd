-- vis_warp_pkg_v2 -- 24bpp RGB888 types + helpers for Phase 2 framework version
--
-- Phase 1 (vis_warp_pkg.vhd) was 8bpp RGB332 with Pac-Man-sized M10K FB.
-- Phase 2 is framework: 24bpp RGB888, DDR3 backend, source-res-agnostic.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package vis_warp_pkg_v2 is

    -- ---- Pixel format: RGB888 packed as 24-bit ----
    constant C_BPP_V2 : integer := 24;

    function rgb888_pack(r, g, b : unsigned(7 downto 0)) return std_logic_vector;
    function rgb888_r  (pix : std_logic_vector(23 downto 0)) return unsigned;
    function rgb888_g  (pix : std_logic_vector(23 downto 0)) return unsigned;
    function rgb888_b  (pix : std_logic_vector(23 downto 0)) return unsigned;

    -- ---- DDR3 (vbuf) interface widths -- mirror what ascal uses on vbuf_* ----
    -- See sys_top.v:696-704 and ascal port at 820-829.
    constant C_VBUF_DW   : integer := 128;   -- data bus width
    constant C_VBUF_AW   : integer := 28;    -- address bus width (byte-addressable, 256 MB)
    constant C_VBUF_BEW  : integer := 16;    -- byte-enable width (= DW/8)
    constant C_VBUF_BCW  : integer := 8;     -- burst count width

    -- ---- DDR3 pixel packing ----
    -- 4 RGB888 pixels per 128-bit word: bits [95:0] used, [127:96] padding.
    -- Pixel 0 lives in [23:0], pixel 1 in [47:24], pixel 2 in [71:48], pixel 3 in [95:72].
    -- Byte address of pixel (x, y) given stride_bytes:
    --   word_addr  = base + (y * stride_bytes) + (x / 4) * 16
    --   word_lane  = x mod 4    -- which of the 4 pixels in the word
    -- stride_bytes = ceil(width_pix / 4) * 16  -- aligned to 128-bit boundary
    constant C_PIXELS_PER_WORD : integer := 4;   -- 4 * 24 = 96 bits used per 128

    function pack_4pix(p0, p1, p2, p3 : std_logic_vector(23 downto 0))
        return std_logic_vector;
    function unpack_pix(word : std_logic_vector(127 downto 0); lane : integer range 0 to 3)
        return std_logic_vector;

    -- Address generator: (x, y, stride_bytes, base_word_addr) -> word address
    -- word_addr is in units of 128-bit words (NOT bytes).
    function pixel_word_addr(x, y : integer; stride_words : integer; base_word : integer)
        return integer;

end package;


package body vis_warp_pkg_v2 is

    function rgb888_pack(r, g, b : unsigned(7 downto 0)) return std_logic_vector is
    begin
        return std_logic_vector(r) & std_logic_vector(g) & std_logic_vector(b);
    end function;

    function rgb888_r(pix : std_logic_vector(23 downto 0)) return unsigned is
    begin
        return unsigned(pix(23 downto 16));
    end function;

    function rgb888_g(pix : std_logic_vector(23 downto 0)) return unsigned is
    begin
        return unsigned(pix(15 downto 8));
    end function;

    function rgb888_b(pix : std_logic_vector(23 downto 0)) return unsigned is
    begin
        return unsigned(pix(7 downto 0));
    end function;

    function pack_4pix(p0, p1, p2, p3 : std_logic_vector(23 downto 0))
        return std_logic_vector is
        variable word : std_logic_vector(127 downto 0) := (others => '0');
    begin
        word(23 downto 0)   := p0;
        word(47 downto 24)  := p1;
        word(71 downto 48)  := p2;
        word(95 downto 72)  := p3;
        -- bits [127:96] left as zero padding
        return word;
    end function;

    function unpack_pix(word : std_logic_vector(127 downto 0); lane : integer range 0 to 3)
        return std_logic_vector is
    begin
        case lane is
            when 0 => return word(23 downto 0);
            when 1 => return word(47 downto 24);
            when 2 => return word(71 downto 48);
            when 3 => return word(95 downto 72);
        end case;
    end function;

    function pixel_word_addr(x, y : integer; stride_words : integer; base_word : integer)
        return integer is
    begin
        return base_word + y * stride_words + (x / C_PIXELS_PER_WORD);
    end function;

end package body;
