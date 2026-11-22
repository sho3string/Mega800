----------------------------------------------------------------------------------
-- Mega800: byte-wide QNICE device backed by HyperRAM
--
-- Replaces the 256 KiB BRAM d1_mount_buf_ram. The M2M vdrives firmware loads
-- the complete mounted image into the buffer device and later reads/writes it
-- one byte per device address (low byte of the 16-bit QNICE data bus).
--
-- Each region is a separate 512 KiB slice of HyperRAM, so vdrive 0 (ATR) and
-- vdrive 1 (CAS) no longer overwrite each other.
--
--    region_i = '0' : D1 / ATR buffer  -> HyperRAM bytes G_D1_BASE  ..+512K
--    region_i = '1' : CAS buffer       -> HyperRAM bytes G_CAS_BASE ..+512K
--
-- HyperRAM side is word addressed (16-bit units); the byte lane is selected via
-- byteenable. Bit 31 of the address must be 0 (bit 31 = HyperRAM register space).
--
-- QNICE side runs on the falling edge, like qnice2hyperram.vhd.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qnice_hyperram_buf is
   generic (
      G_D1_BASE  : natural := 16#780000#;   -- byte address, must be even
      G_CAS_BASE : natural := 16#700000#    -- byte address, must be even
   );
   port (
      -- QNICE clock domain
      qnice_clk_i             : in  std_logic;
      qnice_rst_i             : in  std_logic;
      qnice_cs_i              : in  std_logic;                      -- ce AND device id match
      qnice_region_i          : in  std_logic;                      -- '0' = D1, '1' = CAS
      qnice_we_i              : in  std_logic;
      qnice_addr_i            : in  std_logic_vector(18 downto 0);  -- byte offset in region
      qnice_data_i            : in  std_logic_vector(7 downto 0);
      qnice_data_o            : out std_logic_vector(7 downto 0);
      qnice_wait_o            : out std_logic;

      -- HyperRAM clock domain (to mega65.vhd hr_core_* ports)
      hr_clk_i                : in  std_logic;
      hr_rst_i                : in  std_logic;
      hr_write_o              : out std_logic;
      hr_read_o               : out std_logic;
      hr_address_o            : out std_logic_vector(31 downto 0);
      hr_writedata_o          : out std_logic_vector(15 downto 0);
      hr_byteenable_o         : out std_logic_vector(1 downto 0);
      hr_burstcount_o         : out std_logic_vector(7 downto 0);
      hr_readdata_i           : in  std_logic_vector(15 downto 0);
      hr_readdatavalid_i      : in  std_logic;
      hr_waitrequest_i        : in  std_logic
   );
end entity qnice_hyperram_buf;

architecture synthesis of qnice_hyperram_buf is

   signal byte_addr       : unsigned(22 downto 0);   -- 8 MiB byte address
   signal word_addr       : std_logic_vector(31 downto 0);
   signal byteenable      : std_logic_vector(1 downto 0);
   signal writedata       : std_logic_vector(15 downto 0);
   signal lane_reg        : std_logic := '0';
   signal readdata16      : std_logic_vector(15 downto 0);
   signal wait_int        : std_logic;

   -- QNICE-side Avalon master (before clock domain crossing)
   signal q_avm_write         : std_logic;
   signal q_avm_read          : std_logic;
   signal q_avm_address       : std_logic_vector(31 downto 0);
   signal q_avm_writedata     : std_logic_vector(15 downto 0);
   signal q_avm_byteenable    : std_logic_vector(1 downto 0);
   signal q_avm_burstcount    : std_logic_vector(7 downto 0);
   signal q_avm_readdata      : std_logic_vector(15 downto 0);
   signal q_avm_readdatavalid : std_logic;
   signal q_avm_waitrequest   : std_logic;

begin

   byte_addr <= to_unsigned(G_CAS_BASE, 23) + unsigned(qnice_addr_i) when qnice_region_i = '1' else
                to_unsigned(G_D1_BASE,  23) + unsigned(qnice_addr_i);

   word_addr  <= "0000000000" & std_logic_vector(byte_addr(22 downto 1));
   byteenable <= "10" when byte_addr(0) = '1' else "01";
   writedata  <= qnice_data_i & qnice_data_i;

   -- Remember which byte lane the current read belongs to. The address is held
   -- stable by QNICE for the whole wait period, so re-latching is harmless.
   lane_proc : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         if qnice_cs_i = '1' and wait_int = '0' then
            lane_reg <= byte_addr(0);
         end if;
      end if;
   end process lane_proc;

   qnice_data_o <= readdata16(15 downto 8) when lane_reg = '1' else readdata16(7 downto 0);
   qnice_wait_o <= wait_int;

   i_qnice2hyperram : entity work.qnice2hyperram
      port map (
         clk_i                 => qnice_clk_i,
         rst_i                 => qnice_rst_i,
         s_qnice_wait_o        => wait_int,
         s_qnice_address_i     => word_addr,
         s_qnice_cs_i          => qnice_cs_i,
         s_qnice_write_i       => qnice_we_i,
         s_qnice_writedata_i   => writedata,
         s_qnice_byteenable_i  => byteenable,
         s_qnice_readdata_o    => readdata16,
         m_avm_write_o         => q_avm_write,
         m_avm_read_o          => q_avm_read,
         m_avm_address_o       => q_avm_address,
         m_avm_writedata_o     => q_avm_writedata,
         m_avm_byteenable_o    => q_avm_byteenable,
         m_avm_burstcount_o    => q_avm_burstcount,
         m_avm_readdata_i      => q_avm_readdata,
         m_avm_readdatavalid_i => q_avm_readdatavalid,
         m_avm_waitrequest_i   => q_avm_waitrequest
      );

   -- Clock domain crossing QNICE -> HyperRAM (same settings as the framework's
   -- own QNICE HyperRAM path)
   i_avm_fifo : entity work.avm_fifo
      generic map (
         G_WR_DEPTH     => 16,
         G_RD_DEPTH     => 16,
         G_FILL_SIZE    => 1,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         s_clk_i               => qnice_clk_i,
         s_rst_i               => qnice_rst_i,
         s_avm_waitrequest_o   => q_avm_waitrequest,
         s_avm_write_i         => q_avm_write,
         s_avm_read_i          => q_avm_read,
         s_avm_address_i       => q_avm_address,
         s_avm_writedata_i     => q_avm_writedata,
         s_avm_byteenable_i    => q_avm_byteenable,
         s_avm_burstcount_i    => q_avm_burstcount,
         s_avm_readdata_o      => q_avm_readdata,
         s_avm_readdatavalid_o => q_avm_readdatavalid,
         m_clk_i               => hr_clk_i,
         m_rst_i               => hr_rst_i,
         m_avm_waitrequest_i   => hr_waitrequest_i,
         m_avm_write_o         => hr_write_o,
         m_avm_read_o          => hr_read_o,
         m_avm_address_o       => hr_address_o,
         m_avm_writedata_o     => hr_writedata_o,
         m_avm_byteenable_o    => hr_byteenable_o,
         m_avm_burstcount_o    => hr_burstcount_o,
         m_avm_readdata_i      => hr_readdata_i,
         m_avm_readdatavalid_i => hr_readdatavalid_i
      );

end architecture synthesis;
