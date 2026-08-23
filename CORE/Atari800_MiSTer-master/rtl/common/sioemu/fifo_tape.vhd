/*LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY altera_mf;
USE altera_mf.all;

ENTITY fifo_tape IS
	PORT
	(
		clock		: IN STD_LOGIC ;
		data		: IN STD_LOGIC_VECTOR (31 DOWNTO 0);
		aclr		: IN STD_LOGIC;
		rdreq		: IN STD_LOGIC ;
		wrreq		: IN STD_LOGIC ;
		empty		: OUT STD_LOGIC ;
		full		: OUT STD_LOGIC ;
		q		: OUT STD_LOGIC_VECTOR (31 DOWNTO 0);
		usedw		: OUT STD_LOGIC_VECTOR (7 DOWNTO 0)
	);
END fifo_tape;

ARCHITECTURE SYN OF fifo_tape IS

	SIGNAL sub_wire0	: STD_LOGIC ;
	SIGNAL sub_wire1	: STD_LOGIC ;
	SIGNAL sub_wire2	: STD_LOGIC_VECTOR (31 DOWNTO 0);
	SIGNAL sub_wire3	: STD_LOGIC_VECTOR (7 DOWNTO 0);

	COMPONENT scfifo
	GENERIC (
		add_ram_output_register		: STRING;
		intended_device_family		: STRING;
		lpm_numwords		: NATURAL;
		lpm_showahead		: STRING;
		lpm_type		: STRING;
		lpm_width		: NATURAL;
		lpm_widthu		: NATURAL;
		overflow_checking		: STRING;
		underflow_checking		: STRING;
		use_eab		: STRING
	);
	PORT (
			clock	: IN STD_LOGIC ;
			data	: IN STD_LOGIC_VECTOR (31 DOWNTO 0);
			aclr	: IN STD_LOGIC ;
			rdreq	: IN STD_LOGIC ;
			wrreq	: IN STD_LOGIC ;
			empty	: OUT STD_LOGIC ;
			full	: OUT STD_LOGIC ;
			q	: OUT STD_LOGIC_VECTOR (31 DOWNTO 0);
			usedw	: OUT STD_LOGIC_VECTOR (7 DOWNTO 0)
	);
	END COMPONENT;

BEGIN
	empty <= sub_wire0;
	full <= sub_wire1;
	q <= sub_wire2(31 DOWNTO 0);
	usedw <= sub_wire3(7 DOWNTO 0);

	scfifo_component : scfifo
	GENERIC MAP (
		add_ram_output_register => "OFF",
		intended_device_family => "Cyclone V",
		lpm_numwords => 256,
		lpm_showahead => "ON",
		lpm_type => "scfifo",
		lpm_width => 32,
		lpm_widthu => 8,
		overflow_checking => "ON",
		underflow_checking => "ON",
		use_eab => "ON"
	)
	PORT MAP (
		clock => clock,
		data => data,
		aclr => aclr,
		rdreq => rdreq,
		wrreq => wrreq,
		empty => sub_wire0,
		full => sub_wire1,
		q => sub_wire2,
		usedw => sub_wire3
	);

END SYN;
*/

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fifo_tape is
   port
   (
      clock : in  std_logic;
      data  : in  std_logic_vector(31 downto 0);
      aclr  : in  std_logic;
      rdreq : in  std_logic;
      wrreq : in  std_logic;

      empty : out std_logic;
      full  : out std_logic;
      q     : out std_logic_vector(31 downto 0);
      usedw : out std_logic_vector(7 downto 0)
   );
end entity fifo_tape;

architecture rtl of fifo_tape is

   type ram_t is array (0 to 255) of std_logic_vector(31 downto 0);

   signal ram       : ram_t;
   signal rd_ptr    : unsigned(7 downto 0) := (others => '0');
   signal wr_ptr    : unsigned(7 downto 0) := (others => '0');
   signal count     : unsigned(8 downto 0) := (others => '0');

   signal empty_int : std_logic;
   signal full_int  : std_logic;
   signal do_read   : std_logic;
   signal do_write  : std_logic;

begin

   ---------------------------------------------------------------------------
   -- Status
   ---------------------------------------------------------------------------

   empty_int <= '1' when count = 0   else '0';
   full_int  <= '1' when count = 256 else '0';

   empty <= empty_int;
   full  <= full_int;

   -- Original FIFO has an 8-bit usedw output.
   usedw <= std_logic_vector(count(7 downto 0));

   ---------------------------------------------------------------------------
   -- Show-ahead output
   --
   -- Equivalent to Altera:
   --    lpm_showahead => "ON"
   ---------------------------------------------------------------------------

   q <= ram(to_integer(rd_ptr));

   ---------------------------------------------------------------------------
   -- Effective operations
   ---------------------------------------------------------------------------

   do_read  <= rdreq and not empty_int;

   -- Allow a write when full if a word is simultaneously being removed.
   do_write <= wrreq and (not full_int or do_read);

   ---------------------------------------------------------------------------
   -- FIFO
   ---------------------------------------------------------------------------

   process(clock, aclr)
   begin
      if aclr = '1' then

         rd_ptr <= (others => '0');
         wr_ptr <= (others => '0');
         count  <= (others => '0');

      elsif rising_edge(clock) then

         if do_write = '1' then
            ram(to_integer(wr_ptr)) <= data;
            wr_ptr <= wr_ptr + 1;
         end if;

         if do_read = '1' then
            rd_ptr <= rd_ptr + 1;
         end if;

         case std_logic_vector'(do_write & do_read) is

            when "10" =>
               count <= count + 1;

            when "01" =>
               count <= count - 1;

            when others =>
               null;

         end case;

      end if;
   end process;

end architecture rtl;
