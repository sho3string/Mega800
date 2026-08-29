-- MiSTer2MEGA65 Framework
-- Custom keyboard controller for your core
-- Runs in the clock domain of the core.
-- This is how MiSTer2MEGA65 provides access to the MEGA65 keyboard:
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity keyboard is
port (
clk_main_i : in std_logic;

  key_num_i         : in  integer range 0 to 79;
  key_pressed_n_i   : in  std_logic;

  -- 0 = Atari 800XL keyboard layout
  -- 1 = MEGA65 glyph-oriented layout
  mega65_layout_i   : in  std_logic;
  ps2_key_o         : out std_logic_vector(10 downto 0) := (others => '0');
  keyboard_n_o      : out std_logic_vector(79 downto 0)

);
end entity keyboard;

architecture beh of keyboard is

-- MEGA65 key codes that kb_key_num_i is using while
-- kb_key_pressed_n_i is signalling (low active) which key is pressed
constant m65_ins_del    : integer := 0;
constant m65_return     : integer := 1;
constant m65_horz_crsr  : integer := 2; -- means cursor right in C64 terminology
constant m65_f7         : integer := 3;
constant m65_f1         : integer := 4;
constant m65_f3         : integer := 5;
constant m65_f5         : integer := 6;
constant m65_vert_crsr  : integer := 7; -- means cursor down in C64 terminology
constant m65_3          : integer := 8;
constant m65_w          : integer := 9;
constant m65_a          : integer := 10;
constant m65_4          : integer := 11;
constant m65_z          : integer := 12;
constant m65_s          : integer := 13;
constant m65_e          : integer := 14;
constant m65_left_shift : integer := 15;
constant m65_5          : integer := 16;
constant m65_r          : integer := 17;
constant m65_d          : integer := 18;
constant m65_6          : integer := 19;
constant m65_c          : integer := 20;
constant m65_f          : integer := 21;
constant m65_t          : integer := 22;
constant m65_x          : integer := 23;
constant m65_7          : integer := 24;
constant m65_y          : integer := 25;
constant m65_g          : integer := 26;
constant m65_8          : integer := 27;
constant m65_b          : integer := 28;
constant m65_h          : integer := 29;
constant m65_u          : integer := 30;
constant m65_v          : integer := 31;
constant m65_9          : integer := 32;
constant m65_i          : integer := 33;
constant m65_j          : integer := 34;
constant m65_0          : integer := 35;
constant m65_m          : integer := 36;
constant m65_k          : integer := 37;
constant m65_o          : integer := 38;
constant m65_n          : integer := 39;
constant m65_plus       : integer := 40;
constant m65_p          : integer := 41;
constant m65_l          : integer := 42;
constant m65_minus      : integer := 43;
constant m65_dot        : integer := 44;
constant m65_colon      : integer := 45;
constant m65_at         : integer := 46;
constant m65_comma      : integer := 47;
constant m65_gbp        : integer := 48;
constant m65_asterisk   : integer := 49;
constant m65_semicolon  : integer := 50;
constant m65_clr_home   : integer := 51;
constant m65_right_shift: integer := 52;
constant m65_equal      : integer := 53;
constant m65_arrow_up   : integer := 54; -- symbol, not cursor
constant m65_slash      : integer := 55;
constant m65_1          : integer := 56;
constant m65_arrow_left : integer := 57; -- symbol, not cursor
constant m65_ctrl       : integer := 58;
constant m65_2          : integer := 59;
constant m65_space      : integer := 60;
constant m65_mega       : integer := 61;
constant m65_q          : integer := 62;
constant m65_run_stop   : integer := 63;
constant m65_no_scrl    : integer := 64;
constant m65_tab        : integer := 65;
constant m65_alt        : integer := 66;
constant m65_help       : integer := 67;
constant m65_f9         : integer := 68;
constant m65_f11        : integer := 69;
constant m65_f13        : integer := 70;
constant m65_esc        : integer := 71;
constant m65_capslock   : integer := 72;
constant m65_up_crsr    : integer := 73; -- cursor up
constant m65_left_crsr  : integer := 74; -- cursor left
constant m65_restore    : integer := 75;

signal key_pressed_n              : std_logic_vector(79 downto 0) := (others => '1');
signal m65_8_latched_code         : std_logic_vector(7 downto 0) := x"3E";
signal m65_9_latched_code         : std_logic_vector(7 downto 0) := x"46";

signal m65_semicolon_latched_code : std_logic_vector(8 downto 0) := '0' & x"4C";
signal m65_colon_latched_code     : std_logic_vector(8 downto 0) := '1' & x"7E";
signal m65_comma_latched_code     : std_logic_vector(8 downto 0) := '0' & x"41";
signal m65_dot_latched_code       : std_logic_vector(8 downto 0) := '0' & x"49";
signal m65_slash_latched_code     : std_logic_vector(8 downto 0) := '0' & x"4A";
signal m65_equal_latched_code     : std_logic_vector(8 downto 0) := '0' & x"5B";
signal m65_ins_del_latched_code   : std_logic_vector(8 downto 0) := '0' & x"66";

/*
MEGA65 key	     Atari function
F1	             OPTION
F3	             SELECT
F5	             START
F7	             RESET
F9	             HELP
*/

begin

keyboard_n_o      <= key_pressed_n;

keyboard_state : process(clk_main_i)
begin
   if rising_edge(clk_main_i) then

      if key_pressed_n(key_num_i) /= key_pressed_n_i then

         key_pressed_n(key_num_i) <= key_pressed_n_i;

         case key_num_i is

            when m65_a => 
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"1C";
                
            when m65_b => 
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"32";
            
            when m65_c => 
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"21";
            
            when m65_d => 
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"23";
            
            when m65_e =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"24";
            
            when m65_f =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"2B";
            
            when m65_g => 
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"34";
            
            when m65_h => 
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"33";
            
            when m65_i =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';  
                ps2_key_o(7 downto 0) <= x"43";
            
            when m65_j =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"3B";
            
            when m65_k =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"42";
            
            when m65_l =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"4B";
            
            when m65_m =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"3A";
            
            when m65_n =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"31";
            
            when m65_o =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"44";
            
            when m65_p =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"4D";
            
            when m65_q =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"15";
            
            when m65_r =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"2D";
            
            when m65_s =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"1B";
            
            when m65_t =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"2C";
            
            when m65_u =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"3C";

            when m65_v =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"2A";
            
            when m65_w =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"1D";
            
            when m65_x =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"22";
            
            when m65_y =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"35";
            
            when m65_z =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"1A";
  
            when m65_0 =>
               if mega65_layout_i = '1' and
                  (key_pressed_n(m65_left_shift)  = '0' or
                   key_pressed_n(m65_right_shift) = '0')
               then
                  -- MEGA65 Shift+0 has no Atari equivalent.
                  -- Suppress this key completely.
                  null;
            
               else
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '0';
                  ps2_key_o(7 downto 0) <= x"45";
               end if;
            
            when m65_1 =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"16";
            
            when m65_2 =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"1E";
            
            when m65_3 =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"26";
            
            when m65_4 =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"25";
            
            when m65_5 =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"2E";
        
            when m65_6 =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"36";
            
            when m65_7 =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"3D";
        
            when m65_8 =>

               ps2_key_o(9) <= not key_pressed_n_i;
               ps2_key_o(8) <= '0';
            
               if key_pressed_n_i = '0' then
            
                  -- Key DOWN: choose and remember the Atari key.
                  if mega65_layout_i = '1' and
                     (key_pressed_n(m65_left_shift)  = '0' or
                      key_pressed_n(m65_right_shift) = '0')
                  then
                     -- MEGA65 Shift+8 = (
                     -- Atari Shift+9  = (
                     ps2_key_o(7 downto 0) <= x"46";
                     m65_8_latched_code     <= x"46";
            
                  else
                     ps2_key_o(7 downto 0) <= x"3E";
                     m65_8_latched_code     <= x"3E";
                  end if;
            
               else
            
                  -- Key UP: release exactly the Atari key that was pressed.
                  ps2_key_o(7 downto 0) <= m65_8_latched_code;
            
               end if;
            
            when m65_9 =>

               ps2_key_o(9) <= not key_pressed_n_i;
               ps2_key_o(8) <= '0';
            
               if key_pressed_n_i = '0' then
            
                  if mega65_layout_i = '1' and
                     (key_pressed_n(m65_left_shift)  = '0' or
                      key_pressed_n(m65_right_shift) = '0')
                  then
                     -- MEGA65 Shift+9 = )
                     -- Atari Shift+0  = )
                     ps2_key_o(7 downto 0) <= x"45";
                     m65_9_latched_code     <= x"45";
            
                  else
                     ps2_key_o(7 downto 0) <= x"46";
                     m65_9_latched_code     <= x"46";
                  end if;
            
               else
            
                  ps2_key_o(7 downto 0) <= m65_9_latched_code;
            
               end if;
            
            when m65_space =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0'; 
                ps2_key_o(7 downto 0) <= x"29";
            
            when m65_return =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';  
                ps2_key_o(7 downto 0) <= x"5A";
            
            when m65_comma =>
               if key_pressed_n_i = '0' then
            
                  if mega65_layout_i = '1' and
                     (key_pressed_n(m65_left_shift) = '0' or
                      key_pressed_n(m65_right_shift) = '0')
                  then
                     -- MEGA65 Shift+, -> <
                     -- Private marker E0 7B
                     m65_comma_latched_code <= '1' & x"7B";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"7B";
                  else
                     -- Normal comma
                     m65_comma_latched_code <= '0' & x"41";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '0';
                     ps2_key_o(7 downto 0) <= x"41";
                  end if;
            
               else
                  ps2_key_o(9)          <= '0';
                  ps2_key_o(8)          <= m65_comma_latched_code(8);
                  ps2_key_o(7 downto 0) <= m65_comma_latched_code(7 downto 0);
               end if;
            
            when m65_dot =>
               if key_pressed_n_i = '0' then
            
                  if mega65_layout_i = '1' and
                     key_pressed_n(m65_alt) = '0'
                  then
                     -- MEGA65 ALT+. -> |
                     -- Private marker -> Atari Shift+=
                     m65_dot_latched_code <= '1' & x"78";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"78";
            
                  elsif mega65_layout_i = '1' and
                        (key_pressed_n(m65_left_shift) = '0' or
                         key_pressed_n(m65_right_shift) = '0')
                  then
                     -- MEGA65 Shift+. -> >
                     m65_dot_latched_code <= '1' & x"7A";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"7A";
            
                  else
                     -- Normal .
                     m65_dot_latched_code <= '0' & x"49";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '0';
                     ps2_key_o(7 downto 0) <= x"49";
                  end if;
            
               else
                  ps2_key_o(9)          <= '0';
                  ps2_key_o(8)          <= m65_dot_latched_code(8);
                  ps2_key_o(7 downto 0) <= m65_dot_latched_code(7 downto 0);
               end if;
            
            when m65_slash =>
               if key_pressed_n_i = '0' then
            
                  if mega65_layout_i = '1' and
                     key_pressed_n(m65_alt) = '0'
                  then
                     -- MEGA65 ALT+/ -> \
                     -- Private marker -> Atari Shift++
                     m65_slash_latched_code <= '1' & x"77";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"77";
            
                  else
                     -- Normal /
                     m65_slash_latched_code <= '0' & x"4A";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '0';
                     ps2_key_o(7 downto 0) <= x"4A";
                  end if;
            
               else
                  -- Release exactly what was pressed
                  ps2_key_o(9)          <= '0';
                  ps2_key_o(8)          <= m65_slash_latched_code(8);
                  ps2_key_o(7 downto 0) <= m65_slash_latched_code(7 downto 0);
               end if;
            
            when m65_semicolon =>

               if key_pressed_n_i = '0' then
            
                  if mega65_layout_i = '1' and
                     (key_pressed_n(m65_left_shift) = '0' or
                      key_pressed_n(m65_right_shift) = '0')
                  then
                     -- Shift+; -> ]
                     m65_semicolon_latched_code <= '1' & x"7C";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"7C";
            
                  else
                     -- ;
                     m65_semicolon_latched_code <= '0' & x"4C";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '0';
                     ps2_key_o(7 downto 0) <= x"4C";
                  end if;
            
               else
            
                  ps2_key_o(9)          <= '0';
                  ps2_key_o(8)          <= m65_semicolon_latched_code(8);
                  ps2_key_o(7 downto 0) <= m65_semicolon_latched_code(7 downto 0);
            
               end if;
                
            when m65_colon =>

               if mega65_layout_i = '1' then
            
                  if key_pressed_n_i = '0' then
            
                     if key_pressed_n(m65_left_shift) = '0' or
                        key_pressed_n(m65_right_shift) = '0'
                     then
                        -- Shift+: -> [
                        m65_colon_latched_code <= '1' & x"7D";
            
                        ps2_key_o(9)          <= '1';
                        ps2_key_o(8)          <= '1';
                        ps2_key_o(7 downto 0) <= x"7D";
            
                     else
                        -- : -> synthetic Atari Shift+;
                        m65_colon_latched_code <= '1' & x"7E";
            
                        ps2_key_o(9)          <= '1';
                        ps2_key_o(8)          <= '1';
                        ps2_key_o(7 downto 0) <= x"7E";
                     end if;
            
                  else
            
                     ps2_key_o(9)          <= '0';
                     ps2_key_o(8)          <= m65_colon_latched_code(8);
                     ps2_key_o(7 downto 0) <= m65_colon_latched_code(7 downto 0);
            
                  end if;
            
               else
                  null;
               end if;
                
            when m65_left_shift =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"12";
            
            when m65_right_shift =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"59";
               
            when m65_ctrl =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"14";
            
            when m65_tab =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"0D";
            
            when m65_esc =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"76";
            
            when m65_capslock =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"58";

            when m65_run_stop =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '0';
                ps2_key_o(7 downto 0) <= x"77";
            
            -- atari inverse-video  
            when m65_mega =>
                ps2_key_o(9)          <= not key_pressed_n_i;
                ps2_key_o(8)          <= '1';   -- extended
                ps2_key_o(7 downto 0) <= x"11";
               
            -- DELETE / BACKSPACE
            when m65_ins_del =>
               if key_pressed_n_i = '0' then
            
                  if mega65_layout_i = '1' and
                     key_pressed_n(m65_ctrl) = '0'
                  then
                     -- MEGA65 CTRL+INS/DEL -> Atari CTRL+INSERT
                     m65_ins_del_latched_code <= '1' & x"6E";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"6E";
            
                  elsif mega65_layout_i = '1' and
                        (key_pressed_n(m65_left_shift) = '0' or
                         key_pressed_n(m65_right_shift) = '0')
                  then
                     -- MEGA65 Shift+INS/DEL -> Atari INSERT
                     m65_ins_del_latched_code <= '1' & x"70";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"70";
            
                  else
                     -- Normal DELETE/BACKSPACE
                     m65_ins_del_latched_code <= '0' & x"66";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '0';
                     ps2_key_o(7 downto 0) <= x"66";
                  end if;
            
               else
                  ps2_key_o(9)          <= '0';
                  ps2_key_o(8)          <= m65_ins_del_latched_code(8);
                  ps2_key_o(7 downto 0) <= m65_ins_del_latched_code(7 downto 0);
               end if;
               
            -- Atari -
            when m65_minus =>
               if mega65_layout_i = '1' and
                  (key_pressed_n(m65_left_shift) = '0' or
                   key_pressed_n(m65_right_shift) = '0')
               then
                  -- MEGA65 Shift+- -> nothing
                  null;
               else
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '0';
                  ps2_key_o(7 downto 0) <= x"54";
               end if;
            
            -- Atari =
            when m65_equal =>
               if key_pressed_n_i = '0' then
            
                  if mega65_layout_i = '1' and
                     key_pressed_n(m65_alt) = '0'
                  then
                     -- MEGA65 ALT+= -> _
                     -- Private marker -> Atari Shift+-
                     m65_equal_latched_code <= '1' & x"76";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"76";
            
                  elsif mega65_layout_i = '1' and
                        (key_pressed_n(m65_left_shift) = '0' or
                         key_pressed_n(m65_right_shift) = '0')
                  then
                     -- MEGA65 Shift+= -> nothing
                     null;
            
                  else
                     -- Normal =
                     m65_equal_latched_code <= '0' & x"5B";
            
                     ps2_key_o(9)          <= '1';
                     ps2_key_o(8)          <= '0';
                     ps2_key_o(7 downto 0) <= x"5B";
                  end if;
            
               else
                  ps2_key_o(9)          <= '0';
                  ps2_key_o(8)          <= m65_equal_latched_code(8);
                  ps2_key_o(7 downto 0) <= m65_equal_latched_code(7 downto 0);
               end if;
            
            -- Atari +
            when m65_plus =>
               if mega65_layout_i = '1' and
                  (key_pressed_n(m65_left_shift) = '0' or
                   key_pressed_n(m65_right_shift) = '0')
               then
                  null;
               else
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '0';
                  ps2_key_o(7 downto 0) <= x"52";
               end if;
            
            -- Atari *
            when m65_asterisk =>
               if mega65_layout_i = '1' and
                  (key_pressed_n(m65_left_shift) = '0' or
                   key_pressed_n(m65_right_shift) = '0')
               then
                  null;
               else
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '0';
                  ps2_key_o(7 downto 0) <= x"5D";
               end if;
                
            when m65_up_crsr =>
               if mega65_layout_i = '1' then
                  -- MEGA65 cursor UP -> Atari CTRL + -
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '1';  -- extended
                  ps2_key_o(7 downto 0) <= x"75";
               end if;

            when m65_left_crsr =>
               if mega65_layout_i = '1' then
                  -- MEGA65 cursor LEFT -> Atari CTRL + +
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '1';
                  ps2_key_o(7 downto 0) <= x"6B";
               end if;
            
            when m65_vert_crsr =>
               if mega65_layout_i = '1' then
                  -- MEGA65 cursor DOWN -> Atari CTRL + =
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '1';
                  ps2_key_o(7 downto 0) <= x"72";
               end if;
            
            when m65_horz_crsr =>
               if mega65_layout_i = '1' then
                  -- MEGA65 cursor RIGHT -> Atari CTRL + *
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '1';
                  ps2_key_o(7 downto 0) <= x"74";
               end if;
               
            when m65_at =>
               if mega65_layout_i = '1' then
                  -- Dedicated MEGA65 @ key.
                  -- Private marker -> Atari Shift+8.
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '1';
                  ps2_key_o(7 downto 0) <= x"7F";
               else
                  -- Native Atari layout:
                  -- @ is produced with Shift+8, so this physical key is unused.
                  null;
               end if;
               
             -- Atari *
            when m65_arrow_up =>
               if mega65_layout_i = '1' then
            
                  if key_pressed_n(m65_left_shift) = '0' or
                     key_pressed_n(m65_right_shift) = '0'
                  then
                     -- Shift + ^ has no mapping in MEGA65 mode
                     null;
                  else
                     -- Dedicated MEGA65 ^ key -> Atari Shift+*
                     ps2_key_o(9)          <= not key_pressed_n_i;
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"79";
                  end if;
            
               else
                  null;
               end if;
             
             when m65_clr_home =>
               if mega65_layout_i = '1' then
            
                  if key_pressed_n(m65_left_shift) = '0' or
                     key_pressed_n(m65_right_shift) = '0'
                  then
                     -- MEGA65 Shift+CLR/HOME -> nothing
                     null;
            
                  else
                     -- MEGA65 CLR/HOME -> Atari CLEAR
                     -- Atari CLEAR = Shift+<
                     ps2_key_o(9)          <= not key_pressed_n_i;
                     ps2_key_o(8)          <= '1';
                     ps2_key_o(7 downto 0) <= x"73";
                  end if;
            
               else
                  null;
               end if;
               
             when m65_arrow_left =>
               if mega65_layout_i = '1' then
                  -- MEGA65 ← symbol -> Atari DEL
                  -- Atari DEL = Shift+DELETE/BACKSPACE
                  ps2_key_o(9)          <= not key_pressed_n_i;
                  ps2_key_o(8)          <= '1';
                  ps2_key_o(7 downto 0) <= x"6F";
               else
                  null;
               end if;
             
             when others =>
               null;

        end case;

     end if;

  end if;

end process keyboard_state;

end beh;