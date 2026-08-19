--
-- VHDL Architecture zybo_aes_hdl_lib.aes_rcon.tbl
--
-- Created:
--          by - Shahin.UNKNOWN (DESKTOP-THSND8B)
--          at - 17:26:47 05/25/2026
--
-- using Mentor Graphics HDL Designer(TM) 2019.3 (Build 4)
--
LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.std_logic_arith.all;

ENTITY aes_rcon IS
   PORT(
      round_index : IN  std_logic_vector(3 DOWNTO 0);
      rcon        : OUT std_logic_vector(31 DOWNTO 0)
   );
END ENTITY aes_rcon;

--
ARCHITECTURE tbl OF aes_rcon IS
BEGIN

   WITH round_index SELECT
     rcon <=
        x"01000000" WHEN x"1",
        x"02000000" WHEN x"2",
        x"04000000" WHEN x"3",
        x"08000000" WHEN x"4",
        x"10000000" WHEN x"5",
        x"20000000" WHEN x"6",
        x"40000000" WHEN x"7",
        x"80000000" WHEN x"8",
        x"1B000000" WHEN x"9",
        x"36000000" WHEN x"A",
        x"00000000" WHEN OTHERS;

END ARCHITECTURE tbl;