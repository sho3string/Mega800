-------------------------------------------------------------------------------------------------------------
-- Atari SIO Controller
--
-- Implements the Atari serial I/O (SIO) protocol used by the MEGA65 Atari 800 core to service ATR disk
-- images through the MiSTer2MEGA65 virtual-drive infrastructure.
--
-- The controller interfaces with sio_handler's UART/FIFO registers and currently emulates disk drive D1:.
-- It receives and validates Atari SIO command frames, consumes the COMMAND-line release marker generated
-- by sio_handler, adopts the measured receive baud-rate divisor for transmission, and generates the
-- appropriate ACK/NAK, COMPLETE/ERROR and response-data sequences.
--
-- Currently implemented disk commands:
--
--   $53 STATUS
--      Returns the four-byte Atari disk status block and checksum.
--
--   $52 READ
--      Requests a logical ATR sector from the QNICE-side ATR service, waits for completion through the
--      request/completion CDC handshake, then transmits the sector data and Atari checksum.
--
-- ATR sector data itself is transferred through a dual-clock logical-sector RAM. The QNICE domain fills
-- the RAM before signalling completion; this controller then reads the completed sector synchronously in
-- the Atari main-clock domain.
--
-- SIO peripheral response timing follows the original MiSTer Atari800 firmware (atari800.cpp):
--
--   T2 = 100 us   delay before ACK/NAK
--   T5 = 600 us   delay before COMPLETE/ERROR
--   T3 = 150 us   delay between COMPLETE and response data
--
-- The delays are converted to clk_main_i cycles using clk_main_speed_i so that protocol timing does not
-- depend on a particular FPGA main-clock frequency.
--
-- This module also implements the ATR cold-boot helper used by the MEGA65 port. When OPTION + RESET is
-- explicitly requested with a valid ATR mounted, it initializes the Atari's 64K RAM using the existing
-- DMA interface, performs an Atari reset, and applies the post-reset OPTION pulse required to reproduce
-- the MiSTer cold-boot behaviour. Merely mounting or changing an ATR does not initiate a cold boot,
-- allowing disks to be changed while the Atari continues running.
-------------------------------------------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity atari_sio is
   port (
      clk_main_i       : in  std_logic;
      clk_main_speed_i : in  natural;
      reset_core_n_i   : in  std_logic;

      -- Existing Atari DMA interface used by the ATR cold-boot sequence.
      dma_req_i   : in  std_logic;
      dma_ready_i : in  std_logic;
      
      manual_cold_boot_i : in std_logic;

      atr_boot_dma_active_o   : out std_logic;
      atr_boot_dma_addr_o     : out unsigned(15 downto 0);
      atr_boot_dma_req_o      : out std_logic;
      atr_boot_reset_o        : out std_logic;
      atr_boot_option_force_o : out std_logic;

      -- sio_handler UART register interface.
      uart_data_read_i      : in  std_logic_vector(15 downto 0);
      sio_uart_addr_o       : out std_logic_vector(4 downto 0);
      sio_uart_enable_o     : out std_logic;
      sio_uart_wr_o         : out std_logic;
      sio_uart_data_write_o : out std_logic_vector(7 downto 0);

       -- Current mounted-drive/status information.
      vdrive_mounted_i         : in std_logic;
      vdrive_readonly_i        : in std_logic;
      atr_valid_main_i         : in std_logic;
      atr_sector_count_main_i  : in unsigned(23 downto 0);
      atr_sector_size_main_i   : in unsigned(15 downto 0);

      -- Main-domain side of the existing ATR request/completion CDC.
      sio_atr_req_toggle_main_o : out std_logic_vector(0 downto 0);
      sio_atr_req_sector_main_o : out std_logic_vector(23 downto 0);
      atr_done_toggle_main_i    : in  std_logic_vector(0 downto 0);
      atr_result_meta_main_i    : in  std_logic_vector(10 downto 0);

      -- Main-clock read port for logical-sector RAM.
      atr_sector_read_addr_o : out unsigned(8 downto 0);
      atr_sector_read_data_i : in  std_logic_vector(7 downto 0);

      sio_drive_activity_o : out std_logic
   );
end entity atari_sio;

architecture rtl of atari_sio is

   type t_atr_boot_state is (
      ATR_BOOT_IDLE,
      ATR_BOOT_WRITE_START,
      ATR_BOOT_WRITE_WAIT,
      ATR_BOOT_RESET_ASSERT,
      ATR_BOOT_RESET_RELEASE,
      ATR_BOOT_OPTION_ASSERT,
      ATR_BOOT_OPTION_RELEASE
   );
   
    -- Atari SIO peripheral response timing.
    --
    -- These timings come from the original MiSTer Atari800 firmware
    -- (atari800.cpp):
    --
    --   DELAY_T2_MIN    = 100 us
    --     BiboDos needs at least 50 us delay before ACK.
    --
    --   DELAY_T5_MIN    = 600 us
    --     DOS 2.0S needs at least 600 us delay to function properly.
    --
    --   DELAY_T3_PERIPH = 150 us
    --     QMEG OS 3 needs a 150 us delay between COMPLETE and data.
    --
    -- Convert the firmware's microsecond delays to clk_main_i cycles
    -- using clk_main_speed_i so the SIO timing is independent of the
    -- actual main clock frequency.
   constant SIO_DELAY_T2_US : natural := 100;
   constant SIO_DELAY_T3_US : natural := 150;
   constant SIO_DELAY_T5_US : natural := 600;

   signal atr_boot_state         : t_atr_boot_state := ATR_BOOT_IDLE;
   signal atr_boot_dma_active    : std_logic := '0';
   signal atr_boot_dma_addr      : unsigned(15 downto 0) := (others => '0');
   signal atr_boot_dma_req       : std_logic := '0';
   signal atr_boot_reset         : std_logic := '0';
   signal atr_boot_option_force  : std_logic := '0';
   signal atr_boot_reset_count   : natural range 0 to 65535 := 0;
   signal manual_cold_boot_d     : std_logic := '0';
   signal dma_ready              : std_logic;
   signal reset_core_n           : std_logic;

   signal uart_data_read      : std_logic_vector(15 downto 0);
   signal sio_uart_addr       : std_logic_vector(4 downto 0) := (others => '0');
   signal sio_uart_enable     : std_logic := '0';
   signal sio_uart_wr         : std_logic := '0';
   signal sio_uart_data_write : std_logic_vector(7 downto 0) := (others => '0');

   type t_sio_cmd is array (0 to 4) of std_logic_vector(7 downto 0);
   signal sio_cmd_bytes : t_sio_cmd := (others => (others => '0'));

   type t_sio_command_kind is (
      SIO_COMMAND_NONE,
      SIO_COMMAND_STATUS,
      SIO_COMMAND_READ,
      SIO_COMMAND_NAK
   );

   type t_sio_state is (
      SIO_IDLE,
      SIO_RXSTAT_WAIT,
      SIO_RXSTAT_CAPTURE,
      SIO_RX_READ,
      SIO_RX_WAIT,
      SIO_RX_CAPTURE,
      SIO_VALIDATE,
      SIO_CMDREL_STAT_READ,
      SIO_CMDREL_STAT_WAIT,
      SIO_CMDREL_STAT_CAPTURE,
      SIO_CMDREL_FETCH,
      SIO_CMDREL_FETCH_WAIT,
      SIO_CMDREL_CAPTURE,
      SIO_DIV_READ,
      SIO_DIV_WAIT,
      SIO_DIV_CAPTURE,
      SIO_DIV_WRITE,
      SIO_DELAY_ACK,
      SIO_AFTER_ACK,
      SIO_ATR_WAIT,
      SIO_ATR_SETTLE,
      SIO_DELAY_COMPLETE,
      SIO_AFTER_COMPLETE,
      SIO_DELAY_DATA,
      SIO_STATUS_SEND,
      SIO_STATUS_SENT,
      SIO_READ_FETCH,
      SIO_READ_SEND,
      SIO_READ_SENT,
      SIO_READ_CHECKSUM_SENT,
      SIO_TXSTAT_READ,
      SIO_TXSTAT_WAIT,
      SIO_TXSTAT_CAPTURE,
      SIO_TX_WRITE
   );

   signal sio_state           : t_sio_state := SIO_IDLE;
   signal sio_tx_return_state : t_sio_state := SIO_IDLE;
   signal sio_command_kind    : t_sio_command_kind := SIO_COMMAND_NONE;
   signal sio_rx_index        : integer range 0 to 5 := 0;
   signal sio_cmd_pos_ok      : std_logic := '1';
   signal sio_collecting      : std_logic := '0';
   signal sio_rx_divisor      : std_logic_vector(7 downto 0) := (others => '0');
   signal sio_delay_count     : integer range 0 to 40000 := 0;
   signal sio_settle_count    : integer range 0 to 15 := 0;
   signal sio_tx_byte         : std_logic_vector(7 downto 0) := (others => '0');
   signal sio_status_byte0    : std_logic_vector(7 downto 0);
   signal sio_status_index    : integer range 0 to 4 := 0;
   signal sio_read_index      : unsigned(9 downto 0) := (others => '0');
   signal sio_read_length     : unsigned(9 downto 0) := (others => '0');
   signal sio_read_checksum   : std_logic_vector(7 downto 0) := (others => '0');
   signal sio_read_failed     : std_logic := '0';
   signal sio_status_seen     : std_logic := '0';
   signal sio_read_seen       : std_logic := '0';
   signal sio_drive_activity  : std_logic := '0';
   signal sio_atr_req_toggle_main : std_logic_vector(0 downto 0) := (others => '0');
   signal sio_atr_req_sector_main : std_logic_vector(23 downto 0) := (others => '0');
   signal sio_atr_done_seen       : std_logic := '0';

   signal atr_done_toggle_main : std_logic_vector(0 downto 0);
   signal atr_result_meta_main : std_logic_vector(10 downto 0);
   signal atr_sector_count_main : unsigned(23 downto 0);
   signal atr_valid_main        : std_logic;
   signal vdrives_mounted       : std_logic_vector(0 downto 0);
   
   function sio_make_status0(
      readonly     : std_logic;
      sector_count : unsigned(23 downto 0);
      sector_size  : unsigned(15 downto 0)
   ) return std_logic_vector is
      variable r : unsigned(7 downto 0);
   begin

      -- MiSTer normal mounted-drive STATUS:
      -- bit 4 = motor on
      r := x"10";

      -- bit 3 = write protected
      if readonly = '1' then
         r := r or x"08";
      end if;

      if sector_count = 1040 and sector_size = 128 then
         r := r or x"80";
      end if;

      if sector_size = 256 then
         r := r or x"A0";
      end if;

      return std_logic_vector(r);

   end function;

   function sio_checksum4(
      b0 : std_logic_vector(7 downto 0);
      b1 : std_logic_vector(7 downto 0);
      b2 : std_logic_vector(7 downto 0);
      b3 : std_logic_vector(7 downto 0)
   ) return std_logic_vector is
      variable sum : unsigned(8 downto 0);
      variable r   : unsigned(7 downto 0);
   begin
      r := (others => '0');
      sum := ('0' & r) + unsigned(b0); r := sum(7 downto 0); if sum(8) = '1' then r := r + 1; end if;
      sum := ('0' & r) + unsigned(b1); r := sum(7 downto 0); if sum(8) = '1' then r := r + 1; end if;
      sum := ('0' & r) + unsigned(b2); r := sum(7 downto 0); if sum(8) = '1' then r := r + 1; end if;
      sum := ('0' & r) + unsigned(b3); r := sum(7 downto 0); if sum(8) = '1' then r := r + 1; end if;
      return std_logic_vector(r);
   end function;

   function sio_checksum_add(
      old_sum  : std_logic_vector(7 downto 0);
      new_byte : std_logic_vector(7 downto 0)
   ) return std_logic_vector is
      variable tmp : unsigned(8 downto 0);
      variable res : unsigned(7 downto 0);
   begin
      tmp := ('0' & unsigned(old_sum)) + ('0' & unsigned(new_byte));
      res := tmp(7 downto 0);
      if tmp(8) = '1' then res := res + 1; end if;
      return std_logic_vector(res);
   end function;

begin
   reset_core_n          <= reset_core_n_i;
   dma_ready             <= dma_ready_i;
   uart_data_read        <= uart_data_read_i;
   vdrives_mounted(0)    <= vdrive_mounted_i;
   atr_valid_main        <= atr_valid_main_i;
   atr_sector_count_main <= atr_sector_count_main_i;
   sio_status_byte0      <= sio_make_status0(vdrive_readonly_i,atr_sector_count_main_i,atr_sector_size_main_i);
   atr_done_toggle_main  <= atr_done_toggle_main_i;
   atr_result_meta_main  <= atr_result_meta_main_i;
   atr_sector_read_addr_o <= sio_read_index(8 downto 0);

   atr_boot_dma_active_o   <= atr_boot_dma_active;
   atr_boot_dma_addr_o     <= atr_boot_dma_addr;
   atr_boot_dma_req_o      <= atr_boot_dma_req;
   atr_boot_reset_o        <= atr_boot_reset;
   atr_boot_option_force_o <= atr_boot_option_force;

   sio_uart_addr_o       <= sio_uart_addr;
   sio_uart_enable_o     <= sio_uart_enable;
   sio_uart_wr_o         <= sio_uart_wr;
   sio_uart_data_write_o <= sio_uart_data_write;

   sio_atr_req_toggle_main_o <= sio_atr_req_toggle_main;
   sio_atr_req_sector_main_o <= sio_atr_req_sector_main;
   sio_drive_activity_o      <= sio_drive_activity;

    atr_boot_proc : process(clk_main_i)
    begin
        if rising_edge(clk_main_i) then

                -- defaults
                atr_boot_dma_req      <= '0';
                atr_boot_reset        <= '0';
                atr_boot_option_force <= '0';

            if reset_core_n = '0' then

                atr_boot_state         <= ATR_BOOT_IDLE;
                atr_boot_dma_active    <= '0';
                atr_boot_dma_addr      <= (others => '0');
                atr_boot_reset_count   <= 0;
                manual_cold_boot_d     <= manual_cold_boot_i;

            else

                case atr_boot_state is

                    ----------------------------------------------------------
                    -- Wait for a manual OPTION + RESET cold-boot request.
                    ----------------------------------------------------------
                    when ATR_BOOT_IDLE =>

                        atr_boot_dma_active <= '0';
                    
                        -- Track the manual OPTION + RESET combination.
                        manual_cold_boot_d <= manual_cold_boot_i;
                    
                        -- Start the existing cold-boot sequence only when the user
                        -- presses OPTION + RESET with a valid ATR mounted.
                        if manual_cold_boot_i = '1' and
                           manual_cold_boot_d = '0' and
                           dma_req_i = '0' and
                           atr_valid_main_i = '1' then
                    
                            atr_boot_dma_addr   <= (others => '0');
                            atr_boot_dma_active <= '1';
                    
                            atr_boot_state <= ATR_BOOT_WRITE_START;
                    
                        end if;


                    ----------------------------------------------------------
                    -- Issue one Atari RAM write.
                    --
                    -- Data comes from atari_dma_data_mux:
                    -- even address = FF
                    -- odd  address = 00
                    ----------------------------------------------------------
                    when ATR_BOOT_WRITE_START =>

                        atr_boot_dma_active <= '1';
                        atr_boot_dma_req    <= '1';
                    
                        atr_boot_state <= ATR_BOOT_WRITE_WAIT;
                    
                    
                    ----------------------------------------------------------
                    -- KEEP request asserted until Atari DMA acknowledges it.
                    ----------------------------------------------------------
                    when ATR_BOOT_WRITE_WAIT =>
                    
                        atr_boot_dma_active <= '1';
                        atr_boot_dma_req    <= '1';
                    
                        if dma_ready = '1' then
                    
                            if atr_boot_dma_addr = x"FFFF" then
                                -- All 64K has now been initialized.
                                atr_boot_dma_active  <= '0';
                                atr_boot_reset_count <= 0;
                    
                                atr_boot_state <= ATR_BOOT_RESET_ASSERT;
                    
                            else

                                atr_boot_dma_addr <= atr_boot_dma_addr + 1;
                                atr_boot_state <= ATR_BOOT_WRITE_START;
                            
                            end if;

                        end if;

                    ----------------------------------------------------------
                    -- Hold ordinary Atari reset for ~1 ms.
                    ----------------------------------------------------------
                    when ATR_BOOT_RESET_ASSERT =>
                    
                        atr_boot_reset <= '1';
                    
                        if atr_boot_reset_count >= (clk_main_speed_i / 1000) - 1 then
                    
                            atr_boot_reset_count <= 0;
                            atr_boot_state       <= ATR_BOOT_RESET_RELEASE;
                    
                        else
                    
                            atr_boot_reset_count <= atr_boot_reset_count + 1;
                    
                        end if;


                    ----------------------------------------------------------
                    -- Release reset.
                    ----------------------------------------------------------
                    when ATR_BOOT_RESET_RELEASE =>
                    
                        atr_boot_reset <= '0';
                    
                        atr_boot_state <= ATR_BOOT_OPTION_ASSERT;
                    ----------------------------------------------------------
                    -- Match MiSTer's post-cold-reset OPTION force pulse.
                    ----------------------------------------------------------
                    when ATR_BOOT_OPTION_ASSERT =>
                    
                        atr_boot_option_force <= '1';
                    
                        atr_boot_state <= ATR_BOOT_OPTION_RELEASE;
                        
                    when ATR_BOOT_OPTION_RELEASE =>

                        atr_boot_option_force <= '0';
                    
                        atr_boot_state <= ATR_BOOT_IDLE;   

                  end case;

            end if;

        end if;
    end process;

    sio_controller_proc : process(clk_main_i)
       variable status_tmp : unsigned(7 downto 0);
       variable sector_tmp : unsigned(23 downto 0);
    begin
    
       if rising_edge(clk_main_i) then
    
          ---------------------------------------------------------------
          -- UART controls are strobes.
          ---------------------------------------------------------------
    
          sio_uart_enable <= '0';
          sio_uart_wr     <= '0';
    
    
          if reset_core_n = '0' then
             sio_state            <= SIO_IDLE;
             sio_tx_return_state  <= SIO_IDLE;
    
             sio_uart_addr        <= (others => '0');
             sio_uart_data_write  <= (others => '0');
    
             sio_rx_index         <= 0;
             sio_cmd_pos_ok       <= '1';
             sio_collecting       <= '0';
    
             sio_rx_divisor       <= (others => '0');
    
             sio_command_kind     <= SIO_COMMAND_NONE;
    
             sio_delay_count      <= 0;
             sio_settle_count     <= 0;
    
             sio_tx_byte          <= (others => '0');
    
             sio_status_index     <= 0;  
             sio_read_index       <= (others => '0');
             sio_read_length      <= (others => '0');
             sio_read_checksum    <= (others => '0');
             sio_read_failed      <= '0';
    
             sio_status_seen      <= '0';
             sio_read_seen        <= '0';
             sio_drive_activity   <= '0';
    
             sio_cmd_bytes        <= (others => (others => '0'));
    
             sio_atr_req_toggle_main <= (others => '0');
             sio_atr_req_sector_main <= (others => '0');
    
             sio_atr_done_seen    <= '0';
    
    
          else
             case sio_state is
    
                ----------------------------------------------------------
                -- Poll receive FIFO.
                ----------------------------------------------------------
    
                when SIO_IDLE =>
                   sio_drive_activity <= '0';
                
                   sio_uart_addr   <= "00011";
                   sio_uart_enable <= '1';
                
                   sio_state <= SIO_RXSTAT_WAIT;
                    
    
                when SIO_RXSTAT_WAIT =>
                   sio_state <= SIO_RXSTAT_CAPTURE;
    
    
                when SIO_RXSTAT_CAPTURE =>  
                   -- RX empty bit = 0 means at least one entry exists.
                   if uart_data_read(8) = '0' then
                      if sio_collecting = '0' then
    
                         sio_rx_index   <= 0;
                         sio_cmd_pos_ok <= '1';
                         sio_collecting <= '1';
    
                      end if;
    
                      sio_state <= SIO_RX_READ;
    
                   else  
                      sio_state <= SIO_IDLE;
    
                   end if;
    
    
                ----------------------------------------------------------
                -- Consume one RX FIFO entry.
                ----------------------------------------------------------
    
                when SIO_RX_READ =>  
                   sio_uart_addr   <= "00010";
                   sio_uart_enable <= '1';
    
                   sio_state <= SIO_RX_WAIT;
    
    
                when SIO_RX_WAIT =>   
                   sio_state <= SIO_RX_CAPTURE;
    
    
                when SIO_RX_CAPTURE =>    
                   if sio_rx_index <= 4 then
    
                      -- MiSTer expects command numbers 1..5.
                      if unsigned(uart_data_read(14 downto 8)) /=
                         to_unsigned(sio_rx_index + 1, 7) then
    
                         sio_cmd_pos_ok <= '0';
    
                      end if;
    
                      sio_cmd_bytes(sio_rx_index) <=
                         uart_data_read(7 downto 0);
    
                   end if;
    
    
                   if sio_rx_index = 4 then
                      -- We now have the five actual command entries:
                      --
                      --   1 device
                      --   2 command
                      --   3 AUX1
                      --   4 AUX2
                      --   5 checksum
                      --
                      -- Do NOT consume the sixth FIFO entry here.
                      -- That entry is COMMAND-line release and is
                      -- handled explicitly after validation.
                      sio_collecting <= '0';
                      sio_state      <= SIO_VALIDATE;

                   else
                      sio_rx_index <= sio_rx_index + 1;

                      -- Wait until the next command byte exists.
                      sio_state <= SIO_IDLE;

                   end if;
    
    
                ----------------------------------------------------------
                -- Decode one complete SIO command.
                ----------------------------------------------------------
    
                when SIO_VALIDATE =>
                   sio_command_kind <= SIO_COMMAND_NONE;
                   sio_read_failed  <= '0';
                
                   if sio_cmd_pos_ok = '1' and
                
                      sio_checksum4(
                         sio_cmd_bytes(0),
                         sio_cmd_bytes(1),
                         sio_cmd_bytes(2),
                         sio_cmd_bytes(3)
                      ) = sio_cmd_bytes(4) then
                
                
                      ----------------------------------------------------
                      -- We currently emulate D1 only.
                      ----------------------------------------------------
                
                      if sio_cmd_bytes(0) = x"31" then
                
                
                         -------------------------------------------------
                         -- $53 STATUS
                         -------------------------------------------------
                
                         if sio_cmd_bytes(1) = x"53" then

                           if vdrives_mounted(0) = '1' and
                              atr_valid_main = '1' then
                        
                              sio_command_kind <= SIO_COMMAND_STATUS;
                        
                           else
                        
                              sio_command_kind <= SIO_COMMAND_NONE;
                        
                           end if;
                        
                           sio_state <= SIO_CMDREL_STAT_READ;
                
                
                         -------------------------------------------------
                         -- $52 READ
                         --
                         -- AUX1 = low sector byte
                         -- AUX2 = high sector byte
                         -------------------------------------------------
                
                         elsif sio_cmd_bytes(1) = x"52" then

                       ------------------------------------------------
                       -- TEMP DEBUG:
                       -- proves the Atari issued a valid D1 $52,
                       -- regardless of ATR/mount readiness.
                       ------------------------------------------------
                       sio_read_seen <= '1';
                    
                       if vdrives_mounted(0) = '1' and
                          atr_valid_main = '1' then
                    
                          sector_tmp := (others => '0');
                    
                          sector_tmp(7 downto 0) :=
                             unsigned(sio_cmd_bytes(2));
                    
                          sector_tmp(15 downto 8) :=
                             unsigned(sio_cmd_bytes(3));
                    
                          if sector_tmp >= to_unsigned(1, 24) and
                             sector_tmp <= atr_sector_count_main then
                    
                             sio_atr_req_sector_main <=
                                std_logic_vector(sector_tmp);
                    
                             sio_command_kind <= SIO_COMMAND_READ;
                             sio_drive_activity <= '1';
                    
                          else
                    
                             sio_command_kind <= SIO_COMMAND_NAK;
                    
                          end if;
                    
                       else
                    
                          -- We DID receive $52, but the ATR service
                          -- is not ready for it.
                          sio_command_kind <= SIO_COMMAND_NAK;
                    
                       end if;
                    
                        sio_state <= SIO_CMDREL_STAT_READ;         
                         -------------------------------------------------
                         -- Other D1 commands are not implemented.
                         -------------------------------------------------
                
                         else
                            sio_command_kind <= SIO_COMMAND_NAK;
                            sio_state        <= SIO_CMDREL_STAT_READ;
                         end if;
                
                
                      else
                
                         -------------------------------------------------
                         -- Not D1: ignore.
                         -------------------------------------------------               
                         sio_state <= SIO_IDLE;                
                      end if;
                
                
                   else               
                      ----------------------------------------------------
                      -- Bad command framing/checksum: ignore.
                      ----------------------------------------------------
                
                      sio_state <= SIO_IDLE;                
                   end if;
    
                ----------------------------------------------------------
                -- Wait for command-release marker
                ----------------------------------------------------------
             
    
                ----------------------------------------------------------
                -- Wait for COMMAND-line release entry.
                --
                -- sio_handler places one additional RX FIFO entry into
                -- the FIFO when COMMAND rises. The five command entries
                -- have already been consumed and validated above.
                ----------------------------------------------------------

                when SIO_CMDREL_STAT_READ =>
                   sio_uart_addr   <= "00011";
                   sio_uart_enable <= '1';

                   sio_state <= SIO_CMDREL_STAT_WAIT;


                when SIO_CMDREL_STAT_WAIT =>
                   -- Allow registered DATA_OUT to update.
                   sio_state <= SIO_CMDREL_STAT_CAPTURE;


                when SIO_CMDREL_STAT_CAPTURE =>
                   -- RX empty = 0 means the release entry is available.
                   if uart_data_read(8) = '0' then
                      sio_state <= SIO_CMDREL_FETCH;
                   else
                      sio_state <= SIO_CMDREL_STAT_READ;
                   end if;


                when SIO_CMDREL_FETCH =>
                   -- Consume the COMMAND-release FIFO entry.
                   sio_uart_addr   <= "00010";
                   sio_uart_enable <= '1';

                   sio_state <= SIO_CMDREL_FETCH_WAIT;


                when SIO_CMDREL_FETCH_WAIT =>
                   -- Allow registered DATA_OUT to update.
                   sio_state <= SIO_CMDREL_CAPTURE;


                when SIO_CMDREL_CAPTURE =>
                   -- Release entry has now been consumed.
                
                   if sio_command_kind = SIO_COMMAND_NONE then
                      -- No disk mounted: ignore the command completely.
                      sio_state <= SIO_IDLE;
                   else
                      sio_state <= SIO_DIV_READ;
                   end if;


                ----------------------------------------------------------
                -- Read measured RX divisor.
                ----------------------------------------------------------

                when SIO_DIV_READ =>   
                   sio_uart_addr   <= "00100";
                   sio_uart_enable <= '1';   
                   sio_state <= SIO_DIV_WAIT;
    
    
                when SIO_DIV_WAIT =>  
                   sio_state <= SIO_DIV_CAPTURE;
    
    
                when SIO_DIV_CAPTURE =>   
                   sio_rx_divisor <= uart_data_read(7 downto 0);   
                   sio_state <= SIO_DIV_WRITE;
    
    
                ----------------------------------------------------------
                -- MiSTer uart_switch():
                --
                -- TX divisor = measured RX divisor - 1
                ----------------------------------------------------------
    
                when SIO_DIV_WRITE => 
                   sio_uart_addr <= "00100";
                   if sio_rx_divisor = x"00" then   
                      sio_uart_data_write <= x"FF";   
                   else    
                      sio_uart_data_write <=
                         std_logic_vector(
                            unsigned(sio_rx_divisor) - 1
                         );
    
                   end if;
    
                   sio_uart_wr <= '1';   
                   sio_delay_count <= 0;
                   sio_state       <= SIO_DELAY_ACK;
    
    
                ----------------------------------------------------------
                -- 100us before ACK / NAK.
                ----------------------------------------------------------
    
                when SIO_DELAY_ACK =>

                   if sio_delay_count >=
                        ((clk_main_speed_i * SIO_DELAY_T2_US) / 1_000_000) - 1 then
                
                      sio_delay_count <= 0;
                
                      if sio_command_kind = SIO_COMMAND_NAK then
                
                         sio_tx_byte         <= x"4E"; -- 'N'
                         sio_tx_return_state <= SIO_IDLE;
                
                      else
                
                         sio_tx_byte         <= x"41"; -- 'A'
                         sio_tx_return_state <= SIO_AFTER_ACK;
                
                      end if;
                
                      sio_state <= SIO_TXSTAT_READ;
                
                   else
                
                      sio_delay_count <= sio_delay_count + 1;
                
                   end if;
    
    
                ----------------------------------------------------------
                -- ACK has entered the TX FIFO.
                ----------------------------------------------------------
    
                when SIO_AFTER_ACK =>
                   if sio_command_kind = SIO_COMMAND_STATUS then
    
                      sio_delay_count <= 0;
                      sio_state       <= SIO_DELAY_COMPLETE;
    
    
                   elsif sio_command_kind = SIO_COMMAND_READ then
					   -- Establish completion baseline before launching this request.
					   sio_atr_done_seen <= atr_done_toggle_main(0);

					   sio_atr_req_toggle_main(0) <=
						  not sio_atr_req_toggle_main(0);
					   sio_state <= SIO_ATR_WAIT;
                   else
                      sio_state <= SIO_IDLE;
                   end if;
    
    
                ----------------------------------------------------------
                -- Wait for QNICE sector reader completion.
                ----------------------------------------------------------
    
                when SIO_ATR_WAIT =>
                   if atr_done_toggle_main(0) /=
                      sio_atr_done_seen then
    
                      sio_atr_done_seen <=
                         atr_done_toggle_main(0);
    
                      -- Give result metadata several main clocks to
                      -- settle after the completion-toggle CDC.
                      sio_settle_count <= 0;
                      sio_state        <= SIO_ATR_SETTLE;
    
                   end if;
    
    
                when SIO_ATR_SETTLE =>
                   if sio_settle_count = 7 then
                      sio_settle_count <= 0;
                      if atr_result_meta_main(10) = '1' then
                         sio_read_length <=
                            unsigned(atr_result_meta_main(9 downto 0));
                         sio_read_failed <= '0';
                      else
                         sio_read_length <= (others => '0');
                         sio_read_failed <= '1';
                      end if;
                      sio_delay_count <= 0;
                      sio_state       <= SIO_DELAY_COMPLETE;
                   else
                      sio_settle_count <= sio_settle_count + 1;
                   end if;
    
    
                ----------------------------------------------------------
                -- 600us before COMPLETE / ERROR.
                ----------------------------------------------------------
    
                when SIO_DELAY_COMPLETE =>

                   if sio_delay_count >=
                        ((clk_main_speed_i * SIO_DELAY_T5_US) / 1_000_000) - 1 then
                
                      sio_delay_count <= 0;
                
                      if sio_read_failed = '1' then
                         sio_tx_byte <= x"45"; -- 'E'
                      else
                         sio_tx_byte <= x"43"; -- 'C'
                      end if;
                
                      sio_tx_return_state <= SIO_AFTER_COMPLETE;
                      sio_state           <= SIO_TXSTAT_READ;
                
                   else
                
                      sio_delay_count <= sio_delay_count + 1;
                
                   end if;
    
    
                ----------------------------------------------------------
                -- COMPLETE has entered TX FIFO.
                ----------------------------------------------------------
    
                when SIO_AFTER_COMPLETE =>

                   if sio_read_failed = '1' then
                      sio_drive_activity <= '0';
                      sio_state <= SIO_IDLE;
                
                   else
                
                      sio_delay_count <= 0;
                      sio_state       <= SIO_DELAY_DATA;
                
                   end if;
    
    
                ----------------------------------------------------------
                -- 150us before response payload.
                ----------------------------------------------------------
    
                when SIO_DELAY_DATA =>

                   if sio_delay_count >=
                        ((clk_main_speed_i * SIO_DELAY_T3_US) / 1_000_000) - 1 then
                
                      sio_delay_count <= 0;
                
                      if sio_command_kind = SIO_COMMAND_STATUS then
                
                         sio_status_index <= 0;
                         sio_state        <= SIO_STATUS_SEND;
                
                      else
                
                         sio_read_index    <= (others => '0');
                         sio_read_checksum <= x"00";
                         sio_state         <= SIO_READ_FETCH;
                
                      end if;
                
                   else
                
                      sio_delay_count <= sio_delay_count + 1;
                
                   end if;
                    
    
                ----------------------------------------------------------
                -- Send four STATUS bytes + checksum.
                ----------------------------------------------------------
    
                when SIO_STATUS_SEND =>

                   case sio_status_index is
                
                      when 0 =>
                         sio_tx_byte <= sio_status_byte0;
                
                      when 1 =>
                          sio_tx_byte <= x"FF";
                
                      when 2 =>
                         sio_tx_byte <= x"E0";
                
                      when 3 =>
                         sio_tx_byte <= x"00";
                
                      when others =>
                         sio_tx_byte <=
                             sio_checksum4(
                                 sio_status_byte0,
                                 x"FF",
                                 x"E0",
                                 x"00"
                             );
                
                   end case;
                
                   sio_tx_return_state <= SIO_STATUS_SENT;
                   sio_state           <= SIO_TXSTAT_READ;
                
                
                when SIO_STATUS_SENT =>
                
                   if sio_status_index = 4 then
                
                      sio_status_index <= 0;
                      sio_status_seen  <= '1';
                      sio_state        <= SIO_IDLE;
                
                   else
                
                      sio_status_index <= sio_status_index + 1;
                      sio_state        <= SIO_STATUS_SEND;
                
                   end if;
                   
                ----------------------------------------------------------
                -- Send logical ATR sector bytes.
                ----------------------------------------------------------
                
                when SIO_READ_FETCH =>

                   -- atr_sector_read_addr_o is driven from sio_read_index.
                   -- Wait one main clock for the synchronous RAM read.
                   sio_state <= SIO_READ_SEND;
                
                
                when SIO_READ_SEND =>
                
                   if sio_read_index < sio_read_length then
                
                      sio_tx_byte <= atr_sector_read_data_i;
                
                      sio_tx_return_state <= SIO_READ_SENT;
                      sio_state           <= SIO_TXSTAT_READ;
                
                   else
                
                      -- All payload bytes queued; append Atari checksum.
                      sio_tx_byte <= sio_read_checksum;
                
                      sio_tx_return_state <=
                         SIO_READ_CHECKSUM_SENT;
                
                      sio_state <= SIO_TXSTAT_READ;
                
                   end if;

                when SIO_READ_SENT =>
                   sio_read_checksum <=
                      sio_checksum_add(
                         sio_read_checksum,
                         sio_tx_byte
                      );
    
                   sio_read_index <= sio_read_index + 1;
                   sio_state <= SIO_READ_FETCH;
    
    
                when SIO_READ_CHECKSUM_SENT =>    
                   -- This proves a real ATR logical sector has gone:
                   --
                   -- vdrive -> ATR reader -> SIO TX FIFO.
                   sio_read_seen        <= '1';
                   sio_drive_activity   <= '0';
                   sio_state            <= SIO_IDLE;
    
    
                ----------------------------------------------------------
                -- Common UART TX helper.
                --
                -- ADDR1 bit9 = TX FIFO full.
                --
                -- This is mandatory for sector transfers; we cannot just
                -- blast 128/256 bytes into the small sio_handler FIFO.
                ----------------------------------------------------------
    
                when SIO_TXSTAT_READ =>
                   sio_uart_addr   <= "00001";
                   sio_uart_enable <= '1';
                   sio_state <= SIO_TXSTAT_WAIT;
    
                when SIO_TXSTAT_WAIT =>
                   sio_state <= SIO_TXSTAT_CAPTURE;
    
                when SIO_TXSTAT_CAPTURE =>
                   if uart_data_read(9) = '0' then
                      sio_state <= SIO_TX_WRITE;
                   else
                      -- FIFO still full; poll again.
                      sio_state <= SIO_TXSTAT_READ;
                   end if;
        
                when SIO_TX_WRITE =>
                   sio_uart_addr       <= "00000";
                   sio_uart_data_write <= sio_tx_byte;
                   sio_uart_wr         <= '1';
                   sio_state <= sio_tx_return_state;
    
                when others =>
                   sio_state <= SIO_IDLE;
             end case;
          end if;
       end if;
    end process;

end architecture rtl;
