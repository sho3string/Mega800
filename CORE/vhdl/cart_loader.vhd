----------------------------------------------------------------------------------
-- Mega800: Atari 8-bit cartridge (.CAR) loader
--
-- Official M2M CSR device (same structure as xex_loader.vhd). The M2M manual
-- loader streams the .CAR file into this device:
--
--    bytes 0..15  : CAR header  ("CART", type (big endian, 4 bytes), checksum, 0)
--    bytes 16..   : ROM payload
--
-- The payload is written through the Atari DMA path to the core's cartridge
-- window (DMA address {3'b101, offset} = core SDRAM 0x800000 + offset, which
-- sdram_hyperram_adapter maps to HyperRAM; going through DMA keeps the
-- adapter's cache coherent). Then COLDST ($0244) is set to force an OS cold
-- start, the cartridge mode is driven on cart_mode_o (-> CART1_SELECT_IN) and
-- the Atari is reset.
--
-- CAR type -> core cart mode table: from MiSTer Main_MiSTer
-- support/atari8bit/atari800.cpp (cart_def[]); mode values are the core's
-- cart_logic.vhd cart_mode_* constants.
--
-- Not supported in this version (reported as "Unsupported type"):
--    CAR 3, 45  OSS 034M/043M  (MiSTer reorders 4K blocks and ANDs two banks)
--    CAR 84, 85 Corina          (EEPROM handling)
--    carts > 1 MB               (HyperRAM cartridge window is 1 MB)
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.qnice_csr_pkg.all;

entity cart_loader is
   port (
      -----------------------------------------------------------------------
      -- QNICE interface
      -----------------------------------------------------------------------
      qnice_clk_i       : in  std_logic;
      qnice_rst_i       : in  std_logic;
      qnice_addr_i      : in  std_logic_vector(27 downto 0);
      qnice_data_i      : in  std_logic_vector(15 downto 0);
      qnice_ce_i        : in  std_logic;
      qnice_we_i        : in  std_logic;
      qnice_data_o      : out std_logic_vector(15 downto 0);
      qnice_wait_o      : out std_logic;
      -----------------------------------------------------------------------
      -- Atari DMA interface (shared with xex_loader in mega65.vhd)
      -----------------------------------------------------------------------
      dma_addr_o        : out std_logic_vector(25 downto 0);
      dma_data_o        : out std_logic_vector(7 downto 0);
      dma_read_o        : out std_logic;
      dma_req_toggle_o  : out std_logic;
      dma_ack_toggle_i  : in  std_logic;
      -----------------------------------------------------------------------
      -- Atari control (QNICE clock domain; synchronised in mega65.vhd)
      -----------------------------------------------------------------------
      busy_o            : out std_logic;                     -- owns the DMA path
      cart_mode_o       : out std_logic_vector(7 downto 0);  -- -> CART1_SELECT_IN
      core_reset_o      : out std_logic;
      core_pause_o      : out std_logic
   );
end entity cart_loader;

architecture beh of cart_loader is

   constant C_ERROR_STRINGS : string_vector(0 to 15) := (
       0      => "OK                 \n",
       1      => "Framework error    \n",
       2      => "Not a .CAR file    \n",
       3      => "Unsupported type   \n",
       4      => "Cart too large     \n",
       5      => "Unexpected EOF     \n",
       others => "Unknown error      \n"
   );

   constant C_MAX_PAYLOAD : unsigned(20 downto 0) := to_unsigned(16#100000#, 21);  -- 1 MB
   constant C_COLDST      : std_logic_vector(15 downto 0) := x"0244";

   -- CAR type -> core cart mode (0 = unsupported)
   function car_to_mode(t : unsigned(7 downto 0)) return std_logic_vector is
   begin
      case to_integer(t) is
         when   1 => return x"01";  -- Standard            8K  TC_MODE_8K
         when   2 => return x"21";  -- Standard           16K  TC_MODE_16K
         when   5 => return x"70";  -- DB                 32K  TC_MODE_DB_32
         when   8 => return x"0D";  -- Williams           64K  TC_MODE_WILLIAMS64
         when   9 => return x"0B";  -- Express            64K  TC_MODE_EXPRESS64
         when  10 => return x"0A";  -- Diamond            64K  TC_MODE_DIAMOND64
         when  11 => return x"08";  -- Sparta DOS X       64K  TC_MODE_SDX64
         when  12 => return x"30";  -- XEGS               32K  TC_MODE_XEGS_32
         when  13 => return x"31";  -- XEGS Bank 0-7      64K  TC_MODE_XEGS_64
         when  14 => return x"32";  -- XEGS              128K  TC_MODE_XEGS_128
         when  15 => return x"04";  -- OSS 1 Chip         16K  TC_MODE_OSS_16
         when  17 => return x"0C";  -- Atrax Decoded     128K  TC_MODE_ATRAX128
         when  18 => return x"73";  -- Bounty Bob         40K  TC_MODE_BOUNTY_40
         when  21 => return x"14";  -- Right               8K  TC_MODE_RIGHT_8K
         when  22 => return x"0E";  -- Williams           32K  TC_MODE_WILLIAMS32
         when  23 => return x"33";  -- XEGS              256K  TC_MODE_XEGS_256
         when  24 => return x"34";  -- XEGS              512K  TC_MODE_XEGS_512
         when  25 => return x"35";  -- XEGS             1024K  TC_MODE_XEGS_1024
         when  26 => return x"28";  -- MegaCart           16K  TC_MODE_MEGA_16
         when  27 => return x"29";  -- MegaCart           32K  TC_MODE_MEGA_32
         when  28 => return x"2A";  -- MegaCart           64K  TC_MODE_MEGA_64
         when  29 => return x"2B";  -- MegaCart          128K  TC_MODE_MEGA_128
         when  30 => return x"2C";  -- MegaCart          256K  TC_MODE_MEGA_256
         when  31 => return x"2D";  -- MegaCart          512K  TC_MODE_MEGA_512
         when  32 => return x"2E";  -- MegaCart         1024K  TC_MODE_MEGA_1024
         when  33 => return x"38";  -- Super XEGS         32K  TC_MODE_SXEGS_32
         when  34 => return x"39";  -- Super XEGS         64K  TC_MODE_SXEGS_64
         when  35 => return x"3A";  -- Super XEGS        128K  TC_MODE_SXEGS_128
         when  36 => return x"3B";  -- Super XEGS        256K  TC_MODE_SXEGS_256
         when  37 => return x"3C";  -- Super XEGS        512K  TC_MODE_SXEGS_512
         when  38 => return x"3D";  -- Super XEGS       1024K  TC_MODE_SXEGS_1024
         when  39 => return x"40";  -- Phoenix             8K  TC_MODE_PHOENIX
         when  40 => return x"23";  -- Blizzard           16K  TC_MODE_BLIZZARD
         when  41 => return x"02";  -- Atarimax          128K  TC_MODE_ATARIMAX1
         when  42 => return x"03";  -- Atarimax Old     1024K  TC_MODE_ATARIMAX8
         when  43 => return x"09";  -- Sparta DOS X      128K  TC_MODE_SDX128
         when  44 => return x"05";  -- OSS 1 Chip          8K  TC_MODE_OSS_8
         when  46 => return x"12";  -- Blizzard            4K  TC_MODE_BLIZZARD_4
         when  47 => return x"41";  -- AST                32K  TC_MODE_AST_32
         when  48 => return x"43";  -- Atrax SDX          64K  TC_MODE_ATRAX_SDX64
         when  49 => return x"44";  -- Atrax SDX         128K  TC_MODE_ATRAX_SDX128
         when  50 => return x"45";  -- TurboSoft          64K  TC_MODE_TSOFT_64
         when  51 => return x"46";  -- TurboSoft         128K  TC_MODE_TSOFT_128
         when  52 => return x"47";  -- UltraCart          32K  TC_MODE_ULTRA_32
         when  53 => return x"14";  -- Low Bank XL         8K  TC_MODE_RIGHT_8K
         when  54 => return x"24";  -- S.I.C.            128K  TC_MODE_SIC_128
         when  55 => return x"25";  -- S.I.C.            256K  TC_MODE_SIC_256
         when  56 => return x"26";  -- S.I.C.            512K  TC_MODE_SIC_512
         when  57 => return x"16";  -- Standard            2K  TC_MODE_2K
         when  58 => return x"17";  -- Standard            4K  TC_MODE_4K
         when  59 => return x"15";  -- Right               4K  TC_MODE_RIGHT_4K
         when  60 => return x"13";  -- Blizzard           32K  TC_MODE_BLIZZARD_32
         when  67 => return x"36";  -- XEGS Bank 8-15     64K  TC_MODE_XEGS_64_2
         when  68 => return x"42";  -- Atrax Encoded     128K  TC_MODE_ATRAX_INT128
         when  69 => return x"48";  -- aDawliah           32K  TC_MODE_DAWLI_32
         when  70 => return x"49";  -- aDawliah           64K  TC_MODE_DAWLI_64
         when  75 => return x"10";  -- Atarimax New     1024K  TC_MODE_ATARIMAX8_2
         when  76 => return x"0F";  -- Williams           16K  TC_MODE_WILLIAMS16
         when  80 => return x"4A";  -- JRC-Linear         64K  TC_MODE_JRC_LIN_64
         when  83 => return x"27";  -- S.I.C.+          1024K  TC_MODE_SIC_1024
         when  86 => return x"68";  -- XE Multicart        8K  TC_MODE_XEMULTI_8
         when  87 => return x"69";  -- XE Multicart       16K  TC_MODE_XEMULTI_16
         when  88 => return x"6A";  -- XE Multicart       32K  TC_MODE_XEMULTI_32
         when  89 => return x"6B";  -- XE Multicart       64K  TC_MODE_XEMULTI_64
         when  90 => return x"6C";  -- XE Multicart      128K  TC_MODE_XEMULTI_128
         when  91 => return x"6D";  -- XE Multicart      256K  TC_MODE_XEMULTI_256
         when  92 => return x"6E";  -- XE Multicart      512K  TC_MODE_XEMULTI_512
         when  93 => return x"6F";  -- XE Multicart     1024K  TC_MODE_XEMULTI_1024
         when 104 => return x"18";  -- J(atari)cart        8K  TC_MODE_JATARI_8
         when 105 => return x"19";  -- J(atari)cart       16K  TC_MODE_JATARI_16
         when 106 => return x"1A";  -- J(atari)cart       32K  TC_MODE_JATARI_32
         when 107 => return x"1B";  -- J(atari)cart       64K  TC_MODE_JATARI_64
         when 108 => return x"1C";  -- J(atari)cart      128K  TC_MODE_JATARI_128
         when 109 => return x"1D";  -- J(atari)cart      256K  TC_MODE_JATARI_256
         when 110 => return x"1E";  -- J(atari)cart      512K  TC_MODE_JATARI_512
         when 111 => return x"1F";  -- J(atari)cart     1024K  TC_MODE_JATARI_1024
         when 112 => return x"11";  -- DCART             512K  TC_MODE_DCART
         when 160 => return x"4B";  -- JRC-Interleaved    64K  TC_MODE_JRC_INT_64
         when others => return x"00";
      end case;
   end function car_to_mode;

   type state_t is (
      IDLE_ST, PAUSE_ST, HDR_ST, CHECK_ST, PAYLOAD_ST, DMA_WAIT_ST, RELEASE_ST,
      COLDST_ST, SET_MODE_ST, RESET_HOLD_ST, RESUME_ST, DONE_ST, ERROR_ST
   );
   signal state            : state_t := IDLE_ST;
   signal dma_return_state : state_t := IDLE_ST;
   signal rel_return_state : state_t := IDLE_ST;

   -- CSR
   signal qnice_req_status   : std_logic_vector(3 downto 0);
   signal qnice_req_length   : std_logic_vector(22 downto 0);
   signal qnice_csr_data     : std_logic_vector(15 downto 0);
   signal qnice_csr_wait     : std_logic;
   signal qnice_csr          : std_logic;
   signal qnice_resp_status  : std_logic_vector(3 downto 0) := C_CSR_RESP_IDLE;
   signal qnice_resp_error   : std_logic_vector(3 downto 0) := (others => '0');
   signal qnice_resp_address : std_logic_vector(22 downto 0) := (others => '0');
   signal qnice_wait_reg     : std_logic := '1';

   -- Stream bookkeeping (a held QNICE write is consumed exactly once)
   signal last_stream_addr  : std_logic_vector(27 downto 0) := (others => '0');
   signal stream_addr_valid : std_logic := '0';

   -- Header / payload
   type hdr_t is array (0 to 15) of std_logic_vector(7 downto 0);
   signal hdr          : hdr_t := (others => (others => '0'));
   signal hdr_count    : unsigned(4 downto 0)  := (others => '0');
   signal payload_addr : unsigned(20 downto 0) := (others => '0');
   signal mode_reg     : std_logic_vector(7 downto 0) := (others => '0');
   signal cart_mode    : std_logic_vector(7 downto 0) := (others => '0');

   -- DMA
   signal dma_addr_reg       : std_logic_vector(25 downto 0) := (others => '0');
   signal dma_data_reg       : std_logic_vector(7 downto 0)  := (others => '0');
   signal dma_req_toggle_reg : std_logic := '0';
   signal dma_ack_sync1      : std_logic := '0';
   signal dma_ack_sync2      : std_logic := '0';
   signal dma_ack_seen       : std_logic := '0';

   -- Control
   signal busy        : std_logic := '0';
   signal core_reset  : std_logic := '0';
   signal core_pause  : std_logic := '0';
   signal wait_count  : unsigned(7 downto 0) := (others => '0');

begin

   qnice_csr_inst : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_addr_i,
         qnice_data_i         => qnice_data_i,
         qnice_ce_i           => qnice_ce_i,
         qnice_we_i           => qnice_we_i,
         qnice_data_o         => qnice_csr_data,
         qnice_wait_o         => qnice_csr_wait,
         qnice_csr_o          => qnice_csr,
         qnice_req_status_o   => qnice_req_status,
         qnice_req_length_o   => qnice_req_length,
         qnice_resp_status_i  => qnice_resp_status,
         qnice_resp_error_i   => qnice_resp_error,
         qnice_resp_address_i => qnice_resp_address
      );

   dma_addr_o       <= dma_addr_reg;
   dma_data_o       <= dma_data_reg;
   dma_read_o       <= '0';
   dma_req_toggle_o <= dma_req_toggle_reg;

   busy_o       <= busy;
   cart_mode_o  <= cart_mode;
   core_reset_o <= core_reset;
   core_pause_o <= core_pause;

   qnice_bus_comb : process(all)
   begin
      qnice_data_o <= x"0000";
      qnice_wait_o <= '0';
      if qnice_ce_i = '1' then
         if qnice_csr = '1' then
            qnice_data_o <= qnice_csr_data;
            qnice_wait_o <= qnice_csr_wait;
         else
            qnice_wait_o <= qnice_wait_reg;
         end if;
      end if;
   end process qnice_bus_comb;

   qnice_proc : process(qnice_clk_i)
      variable live_byte_v : boolean;
      variable byte_v      : std_logic_vector(7 downto 0);
      variable type_v      : unsigned(7 downto 0);

      -- start a new load (from IDLE, DONE or ERROR)
      procedure start_load is
      begin
         qnice_wait_reg     <= '1';
         last_stream_addr   <= (others => '0');
         stream_addr_valid  <= '0';
         hdr_count          <= (others => '0');
         payload_addr       <= (others => '0');
         qnice_resp_error   <= (others => '0');
         qnice_resp_address <= (others => '0');
         dma_ack_seen       <= dma_ack_sync2;   -- align to the current ACK toggle
         qnice_resp_status  <= C_CSR_RESP_PARSING;
         busy               <= '1';
         core_pause         <= '1';
         wait_count         <= (others => '0');
         state              <= PAUSE_ST;
      end procedure start_load;

      procedure fail(code : std_logic_vector(3 downto 0)) is
      begin
         qnice_resp_error <= code;
         state            <= ERROR_ST;
      end procedure fail;

   begin
      if falling_edge(qnice_clk_i) then

         dma_ack_sync1 <= dma_ack_toggle_i;
         dma_ack_sync2 <= dma_ack_sync1;

         if qnice_rst_i = '1' then
            state              <= IDLE_ST;
            qnice_resp_status  <= C_CSR_RESP_IDLE;
            qnice_resp_error   <= (others => '0');
            qnice_resp_address <= (others => '0');
            qnice_wait_reg     <= '1';
            stream_addr_valid  <= '0';
            busy               <= '0';
            core_reset         <= '0';
            core_pause         <= '0';
            cart_mode          <= (others => '0');
            dma_req_toggle_reg <= '0';
            dma_ack_seen       <= '0';
         else

            qnice_wait_reg <= '1';

            live_byte_v := qnice_ce_i = '1' and qnice_csr = '0' and qnice_we_i = '1' and
                           (stream_addr_valid = '0' or qnice_addr_i /= last_stream_addr);
            byte_v := qnice_data_i(7 downto 0);

            if qnice_req_status = C_CSR_REQ_ERR and busy = '1' then
               fail(x"1");
            else
               case state is

                  when IDLE_ST =>
                     qnice_resp_status <= C_CSR_RESP_IDLE;
                     qnice_wait_reg    <= '0';
                     if qnice_req_status = C_CSR_REQ_LDNG then
                        start_load;
                     end if;

                  -- Pause the Atari and let the pause reach the Atari clock domain
                  when PAUSE_ST =>
                     if wait_count = 63 then
                        state <= HDR_ST;
                     else
                        wait_count <= wait_count + 1;
                     end if;

                  -- 16 header bytes
                  when HDR_ST =>
                     if live_byte_v then
                        hdr(to_integer(hdr_count(3 downto 0))) <= byte_v;
                        last_stream_addr  <= qnice_addr_i;
                        stream_addr_valid <= '1';
                        hdr_count         <= hdr_count + 1;
                        if hdr_count = 15 then
                           rel_return_state <= CHECK_ST;
                        else
                           rel_return_state <= HDR_ST;
                        end if;
                        state <= RELEASE_ST;
                     elsif qnice_req_status = C_CSR_REQ_OK then
                        fail(x"5");                              -- EOF inside header
                     end if;

                  when CHECK_ST =>
                     type_v := unsigned(hdr(7));
                     if hdr(0) /= x"43" or hdr(1) /= x"41" or hdr(2) /= x"52" or hdr(3) /= x"54" then
                        fail(x"2");                              -- not "CART"
                     elsif hdr(4) /= x"00" or hdr(5) /= x"00" or hdr(6) /= x"00" or
                           car_to_mode(type_v) = x"00" then
                        fail(x"3");                              -- unknown / unsupported type
                     else
                        mode_reg <= car_to_mode(type_v);
                        state    <= PAYLOAD_ST;
                     end if;

                  -- ROM payload -> cartridge window via DMA
                  when PAYLOAD_ST =>
                     if live_byte_v then
                        if payload_addr = C_MAX_PAYLOAD then
                           fail(x"4");                           -- more than 1 MB
                        else
                           dma_addr_reg       <= "101" & "000" & std_logic_vector(payload_addr(19 downto 0));
                           dma_data_reg       <= byte_v;
                           dma_req_toggle_reg <= not dma_req_toggle_reg;
                           payload_addr       <= payload_addr + 1;
                           last_stream_addr   <= qnice_addr_i;
                           stream_addr_valid  <= '1';
                           dma_return_state   <= RELEASE_ST;
                           rel_return_state   <= PAYLOAD_ST;
                           state              <= DMA_WAIT_ST;
                        end if;
                     elsif qnice_req_status = C_CSR_REQ_OK then
                        if payload_addr = 0 then
                           fail(x"5");                           -- header only
                        else
                           state <= COLDST_ST;
                        end if;
                     end if;

                  when DMA_WAIT_ST =>
                     if dma_ack_sync2 /= dma_ack_seen then
                        dma_ack_seen <= dma_ack_sync2;
                        state        <= dma_return_state;
                     end if;

                  -- Release the held QNICE write; continue once it is gone
                  when RELEASE_ST =>
                     if qnice_ce_i = '1' and qnice_csr = '0' and qnice_we_i = '1' and
                        stream_addr_valid = '1' and qnice_addr_i = last_stream_addr then
                        qnice_wait_reg <= '0';
                     else
                        state <= rel_return_state;
                     end if;

                  -- Force an OS cold start (COLDST <> 0) so the cartridge is initialised
                  when COLDST_ST =>
                     dma_addr_reg       <= "0000000000" & C_COLDST;
                     dma_data_reg       <= x"01";
                     dma_req_toggle_reg <= not dma_req_toggle_reg;
                     dma_return_state   <= SET_MODE_ST;
                     state              <= DMA_WAIT_ST;

                  when SET_MODE_ST =>
                     cart_mode  <= mode_reg;
                     core_reset <= '1';
                     wait_count <= (others => '0');
                     state      <= RESET_HOLD_ST;

                  when RESET_HOLD_ST =>
                     if wait_count = 127 then
                        core_reset <= '0';
                        wait_count <= (others => '0');
                        state      <= RESUME_ST;
                     else
                        wait_count <= wait_count + 1;
                     end if;

                  when RESUME_ST =>
                     if wait_count = 63 then
                        core_pause        <= '0';
                        busy              <= '0';
                        qnice_resp_status <= C_CSR_RESP_READY;
                        state             <= DONE_ST;
                     else
                        wait_count <= wait_count + 1;
                     end if;

                  when DONE_ST =>
                     qnice_wait_reg    <= '0';
                     qnice_resp_status <= C_CSR_RESP_READY;
                     if qnice_req_status = C_CSR_REQ_LDNG then
                        start_load;
                     elsif qnice_req_status = C_CSR_REQ_IDLE then
                        qnice_resp_status <= C_CSR_RESP_IDLE;
                        state <= IDLE_ST;
                     end if;

                  -- On error the previous cartridge mode is left unchanged; the
                  -- Atari is released again.
                  when ERROR_ST =>
                     qnice_wait_reg    <= '0';
                     qnice_resp_status <= C_CSR_RESP_ERROR;
                     core_reset        <= '0';
                     core_pause        <= '0';
                     busy              <= '0';
                     if qnice_req_status = C_CSR_REQ_LDNG then
                        start_load;
                     elsif qnice_req_status = C_CSR_REQ_IDLE then
                        qnice_resp_status <= C_CSR_RESP_IDLE;
                        qnice_resp_error  <= (others => '0');
                        state <= IDLE_ST;
                     end if;

               end case;
            end if;
         end if;
      end if;
   end process qnice_proc;

end architecture beh;
